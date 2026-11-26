//go:build ceph_luks_header_session

// Command header-session-check changes the keyslots of an RBD image with
// the header session of go-ceph and the cryptsetup package of the provider.
// It is built inside the ceph-provider module, see build.sh.
//
//	header-session-check [flags] add|remove|list <image>
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/ceph/go-ceph/rados"
	"github.com/ceph/go-ceph/rbd"
	"github.com/ironcore-dev/ceph-provider/internal/cryptsetup"
)

var (
	monitors = flag.String("m", "", "monitor addresses")
	user     = flag.String("id", "admin", "Ceph user without the client. prefix")
	keyring  = flag.String("keyring", "", "keyring file")
	pool     = flag.String("p", "", "pool")
	keyFile  = flag.String("key-file", "", "add: a passphrase in use. remove: the passphrase to remove")
	newFile  = flag.String("new-key-file", "", "add: the new passphrase. remove: a passphrase that has to stay")
	lockMode = flag.String("lock", "transient", "lock around the commit: none, transient or exclusive")
	hold     = flag.Duration("hold", 0, "time to keep the lock before the commit")
	cephOpts = flag.String("ceph-opts", "", "Ceph options for this client, key=value separated by commas")
)

// the cost a rotation gives a new keyslot
var fixedCost = cryptsetup.PBKDF{Type: cryptsetup.Argon2id, Iterations: 4, MemoryKiB: 64 * 1024, Threads: 4}

func main() {
	flag.Parse()
	if flag.NArg() != 2 {
		fmt.Fprintln(os.Stderr, "usage: header-session-check [flags] add|remove|list <image>")
		os.Exit(2)
	}
	if err := run(flag.Arg(0), flag.Arg(1)); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(command, image string) error {
	conn, err := rados.NewConnWithUser(*user)
	if err != nil {
		return err
	}
	if err := conn.ParseCmdLineArgs([]string{"--no-config-file", "-m", *monitors, "--keyring", *keyring}); err != nil {
		return err
	}
	for _, opt := range strings.Split(*cephOpts, ",") {
		if key, value, ok := strings.Cut(opt, "="); ok {
			if err := conn.SetConfigOption(key, value); err != nil {
				return fmt.Errorf("set %s: %w", opt, err)
			}
		}
	}
	if err := conn.Connect(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer conn.Shutdown()
	ioctx, err := conn.OpenIOContext(*pool)
	if err != nil {
		return fmt.Errorf("open pool: %w", err)
	}
	defer ioctx.Destroy()

	start := time.Now()
	since := func() string { return fmt.Sprintf("%.2fs", time.Since(start).Seconds()) }

	img, err := rbd.OpenImage(ioctx, image, rbd.NoSnapshot)
	if err != nil {
		return fmt.Errorf("open image: %w", err)
	}
	defer func() { _ = img.Close() }()
	hdr, err := img.EncryptionLUKSHeaderOpen()
	if err != nil {
		return fmt.Errorf("open header session: %w", err)
	}
	defer func() { _ = hdr.Close() }()
	path, err := hdr.Path()
	if err != nil {
		return err
	}
	dev, err := cryptsetup.Open(path)
	if err != nil {
		return err
	}
	defer dev.Close()
	fmt.Printf("staged at %s\n", since())

	switch command {
	case "list":
		keyslots, err := dev.Keyslots()
		if err != nil {
			return err
		}
		for _, k := range keyslots {
			fmt.Printf("keyslot %d: %+v\n", k.ID, k.PBKDF)
		}
		return nil
	case "add":
		if err := add(dev); err != nil {
			return err
		}
	case "remove":
		if err := remove(dev); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unknown command %q", command)
	}
	// libcryptsetup lets go of the file before librbd reads it
	dev.Close()
	fmt.Printf("header changed at %s\n", since())

	switch *lockMode {
	case "none":
	case "transient":
		err = img.LockAcquire(rbd.LockModeExclusiveTransient)
	case "exclusive":
		err = img.LockAcquire(rbd.LockModeExclusive)
	default:
		err = fmt.Errorf("unknown lock mode %q", *lockMode)
	}
	if err != nil {
		return fmt.Errorf("acquire lock: %w", err)
	}
	fmt.Printf("lock %s at %s\n", *lockMode, since())
	time.Sleep(*hold)

	fmt.Printf("commit starts at %s, unix %.3f\n", since(), float64(time.Now().UnixNano())/1e9)
	err = hdr.Commit()
	fmt.Printf("commit ends at %s, unix %.3f\n", since(), float64(time.Now().UnixNano())/1e9)
	if *lockMode != "none" {
		if lerr := img.LockRelease(); lerr != nil {
			fmt.Printf("release lock: %v\n", lerr)
		}
		fmt.Printf("lock released at %s\n", since())
	}
	if err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

func readKey(path string) ([]byte, error) {
	if path == "" {
		return nil, fmt.Errorf("-key-file and -new-key-file are needed")
	}
	return os.ReadFile(path)
}

func add(dev *cryptsetup.Device) error {
	key, err := readKey(*keyFile)
	if err != nil {
		return err
	}
	newKey, err := readKey(*newFile)
	if err != nil {
		return err
	}
	if err := dev.SetPBKDF(fixedCost); err != nil {
		return err
	}
	slot, err := dev.AddKeyslot(cryptsetup.AnyKeyslot, key, newKey)
	if err != nil {
		return err
	}
	fmt.Printf("keyslot %d added\n", slot)
	return nil
}

func remove(dev *cryptsetup.Device) error {
	key, err := readKey(*keyFile)
	if err != nil {
		return err
	}
	keep, err := readKey(*newFile)
	if err != nil {
		return err
	}
	slot, err := dev.CheckPassphrase(cryptsetup.AnyKeyslot, key)
	if err != nil {
		return fmt.Errorf("find the keyslot to remove: %w", err)
	}
	kept, err := dev.CheckPassphrase(cryptsetup.AnyKeyslot, keep)
	if err != nil {
		return fmt.Errorf("the passphrase that has to stay opens no keyslot: %w", err)
	}
	if kept == slot {
		return fmt.Errorf("both passphrases open keyslot %d", slot)
	}
	if err := dev.RemoveKeyslot(slot); err != nil {
		return err
	}
	fmt.Printf("keyslot %d removed, keyslot %d stays\n", slot, kept)
	return nil
}
