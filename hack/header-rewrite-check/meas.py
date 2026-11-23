#!/usr/bin/env python3
"""Run a command, report wall time, the child's peak RSS and the cgroup's peak memory."""
import resource
import subprocess
import sys
import threading
import time

CG = "/sys/fs/cgroup/"


def cur():
    return int(open(CG + "memory.current").read())


def events():
    return dict(l.split() for l in open(CG + "memory.events"))


base, ev0, peak, stop = cur(), events(), [0], threading.Event()


def sample():
    while not stop.is_set():
        peak[0] = max(peak[0], cur())
        time.sleep(0.01)


t = threading.Thread(target=sample)
t.start()
t0 = time.monotonic()
rc = subprocess.call(sys.argv[1:])
wall = time.monotonic() - t0
stop.set()
t.join()
ev1 = events()
mib = 1024 * 1024
print("rc=%d wall=%.1fs child_maxrss=%.0fMiB cgroup base=%.0fMiB peak=%.0fMiB (+%.0fMiB) limit=%s oom_kill=+%d max_events=+%d" % (
    rc, wall, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024,
    base / mib, peak[0] / mib, (peak[0] - base) / mib,
    open(CG + "memory.max").read().strip(),
    int(ev1["oom_kill"]) - int(ev0["oom_kill"]), int(ev1["max"]) - int(ev0["max"])))
sys.exit(rc)
