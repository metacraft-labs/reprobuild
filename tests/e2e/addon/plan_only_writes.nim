## What a plan-only ``repro anywhere --mode addon`` run may leave on a
## guest's disks, and how a gate finds out what it did leave.
##
## Anywhere Safety Contract §5 (add-on exception, approved by Zahary
## Karadjov on 2026-11-13): the ephemeral probe "writes no file on any
## disk-backed filesystem"; the only writes it may cause are the incidental
## SSH ones (authentication and accounting logs, last-login; access times),
## which are disclosed. The base fingerprint covers only the paths an add-on
## could own, so it cannot see a write to ``/root``, ``/var/tmp`` or the
## rest of ``/var/lib``. This module is the gate's second witness: before
## the run the gate records the guest's clock, afterwards it lists every
## path on every disk-backed filesystem whose content or metadata changed
## since, and refuses each one that is not on ``PlanOnlyAllowedWrites``.
##
## The allowlist is explicit and short on purpose: the contract forbids
## excluding logs to manufacture a zero-write verdict, so an entry is a
## named, justified path and never a directory that merely contains logs.
## Access times are not listed at all (``find`` is asked for modification
## and inode-change times only), which is the contract's disclosed
## exception for them. ``t_addon_plan_only_write_allowlist`` is the
## positive control: files in ``/var/tmp``, ``/root`` and ``/var/lib`` are
## unexplained, the disclosed SSH writes are not.
##
## No VM and no mocks here; the gate runs the listing in the guest.

import std/[strutils]

type AllowedWrite* = object
  path*: string      ## exact path, or a directory prefix when it ends in "/"
  reason*: string    ## why an SSH login may write it

const PlanOnlyAllowedWrites* = [
  AllowedWrite(path: "/var/log", reason:
    "the directory entry changes when a log below it is created or rotated"),
  AllowedWrite(path: "/var/log/wtmp", reason: "login accounting (utmp)"),
  AllowedWrite(path: "/var/log/btmp", reason: "failed-login accounting"),
  AllowedWrite(path: "/var/log/lastlog", reason: "last-login record"),
  AllowedWrite(path: "/var/log/faillog", reason: "failed-login record"),
  AllowedWrite(path: "/var/log/auth.log", reason: "sshd authentication log"),
  AllowedWrite(path: "/var/log/secure", reason: "sshd authentication log"),
  AllowedWrite(path: "/var/log/syslog", reason: "syslog copy of sshd's log"),
  AllowedWrite(path: "/var/log/messages", reason: "syslog copy of sshd's log"),
  AllowedWrite(path: "/var/log/journal/", reason:
    "systemd-journald, which records sshd's and the login session's units")]

# The mount points whose source is a block device. Pseudo, memory and
# network filesystems have no source under /dev and are not disk-backed.
const DiskBackedMountsScript* =
  "findmnt -rn -o TARGET,SOURCE | awk '$2 ~ /^\\/dev\\// {print $1}'"

proc listWritesScript*(sinceEpoch: string): string =
  ## Shell for the guest: every path on each disk-backed filesystem whose
  ## modification or inode-change time is after ``sinceEpoch`` (the
  ## ``date +%s.%N`` the gate took before the run). ``-xdev`` keeps each
  ## walk on its own filesystem. Access times are deliberately not asked
  ## for. Needs bash (pipefail). Exit status is the walk's: a mount that cannot be read fails the
  ## gate instead of reading as "no writes".
  doAssert sinceEpoch.len > 0 and
    sinceEpoch.allCharsInSet({'0'..'9', '.'}), "not an epoch time: " & sinceEpoch
  # ``find -xdev`` still prints a mount point that is itself another
  # filesystem (``/run``, whose own root changes with every file below it),
  # so a printed path that is a mount point outside the disk-backed set is
  # dropped: what it holds is not on a disk.
  "set -eo pipefail; D=$(" & DiskBackedMountsScript & "); " &
    "for m in $D; do find \"$m\" -xdev \\( -newermt @" & sinceEpoch &
    " -o -newerct @" & sinceEpoch & " \\) -print; done | " &
    "while IFS= read -r p; do if mountpoint -q -- \"$p\" && " &
    "! printf '%s\\n' \"$D\" | grep -qxF -- \"$p\"; then continue; fi; " &
    "printf '%s\\n' \"$p\"; done"

proc isAllowedWrite*(path: string): bool =
  for a in PlanOnlyAllowedWrites:
    if a.path.endsWith('/'):
      if path.startsWith(a.path) or path == a.path[0 .. ^2]: return true
    elif path == a.path:
      return true
  false

proc unexplainedWrites*(listing: string): seq[string] =
  ## The listed paths the plan-only run is not allowed to have written.
  for line in listing.splitLines():
    let p = line.strip()
    if p.len > 0 and not isAllowedWrite(p): result.add(p)
