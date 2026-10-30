## ``repro system addon uninstall [--keep-store]``.
##
## Reverses everything the ledger records, in the order the add-on's
## specification fixes:
##
## 1. stop and disable the add-on's units (which removes their install
##    links and, for ``repro-store.mount``, unmounts the store);
## 2. remove the units (and any install link ``disable`` left);
## 3. remove each diversion: the file a generation put at the diverted path
##    first, then ``dpkg-divert --local --rename --remove``, which moves the
##    package's file back;
## 4. remove the ``/etc`` files and the directories the add-on created, then
##    ``systemctl daemon-reload``;
## 5. remove the add-on's state and keys, ``/etc/repro``, and the store
##    (unless ``--keep-store``).
##
## An object whose digest no longer matches the ledger is NOT removed: it
## is reported as drift and left for a human, and the uninstall exits
## non-zero. Accounts the add-on created would be listed and kept (a reused
## UID would hand the files the old account owns to a new owner); generation
## 0 creates none.
##
## The contract is tested as byte identity of the base fingerprint
## (``e2e_addon_bootstrap_uninstall_byte_identity``), with a negative
## control built with ``-d:reproAddonMutation=uninstall-skips-diversion-removal``.

import std/[algorithm, os, sets, strutils]

import ./addon_apply
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./store_root

type
  UninstallOptions* = object
    stateDir*: string
    keepStore*: bool

  UninstallResult* = object
    removed*: seq[string]
    drift*: seq[string]          ## objects left in place, with the reason
    keptAccounts*: seq[string]
      ## Accounts the add-on created and leaves in place (spec: sysusers
      ## accounts are never deleted). Empty in this release: generation 0
      ## creates none, and ``linux.sysusersEntry`` / the account-creating
      ## kinds are not yet add-on-managed (``AddonManagedKinds``). The
      ## milestone that adds them fills this from their ledger entries.
    errors*: seq[string]

proc ok*(r: UninstallResult): bool = r.drift.len == 0 and r.errors.len == 0

proc removeOwned(e: LedgerEntry; r: var UninstallResult) =
  ## Remove one file or link the ledger owns, if it is unchanged.
  let d = observeDrift(e)
  if d.len > 0:
    if d.startsWith("missing"):
      return                       # already gone: nothing to undo
    r.drift.add(e.path & ": " & d)
    return
  try:
    removeFile(e.path)
    r.removed.add(e.path)
  except OSError as ex:
    r.errors.add(e.path & ": " & ex.msg)

proc systemctlOrRecord(args: openArray[string]; r: var UninstallResult) =
  try:
    let res = runSystemctl(args)
    if res.exitCode != 0:
      r.errors.add("systemctl " & args.join(" ") & ": " & res.output.strip())
  except HostToolMissing as ex:
    r.errors.add(ex.msg)

proc runAddonUninstall*(opts: UninstallOptions): UninstallResult =
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  let l = readLedger(ledgerCopyPath(stateDir))
  var byClass: array[LedgerClass, seq[LedgerEntry]]
  for e in l.entries:
    byClass[e.class].add(e)
  # Later entries were created later: undo them first.
  for c in LedgerClass:
    byClass[c].reverse()

  # 1. Stop and disable every unit. `disable` removes the [Install] links;
  #    stopping repro-store.mount unmounts the store's read-only bind.
  for u in byClass[lcUnit]:
    if fileExists(u.path):
      systemctlOrRecord(["disable", "--now", u.unit], result)

  # 2. Units, and any install link `disable` did not remove.
  for li in byClass[lcInstallLink]:
    removeOwned(li, result)
  for u in byClass[lcUnit]:
    removeOwned(u, result)

  # 3. Diversions: the profile's file at the path, then the diversion.
  var handled = initHashSet[string]()
  when not mutated("uninstall-skips-diversion-removal"):
    for dv in byClass[lcDiversion]:
      for f in byClass[lcEtcFile]:
        if f.path == dv.path:
          removeOwned(f, result)
          handled.incl(f.path)
      if fileExists(dv.path) or symlinkExists(dv.path):
        result.drift.add(dv.path & ": a file the ledger does not own sits " &
          "on the diverted path; the diversion is left in place")
        continue
      let exe = resolveHostTool(DpkgDivertCandidates)
      if exe.len == 0:
        result.errors.add(dv.path & ": dpkg-divert is not installed")
        continue
      let res = runHostTool([exe, "--local", "--rename", "--remove", dv.path])
      if res.exitCode != 0:
        result.errors.add("dpkg-divert --remove " & dv.path & ": " &
                          res.output.strip())
      else:
        result.removed.add("diversion " & dv.path)

  # 4. /etc files (those a diversion step did not already take), then the
  #    directories the add-on created, deepest first.
  for f in byClass[lcEtcFile]:
    if f.path in handled:
      continue
    if f.replaced.len > 0 and f.replaced.startsWith("f "):
      var restoredByDiversion = false
      for dv in byClass[lcDiversion]:
        if dv.path == f.path: restoredByDiversion = true
      if not restoredByDiversion:
        result.drift.add(f.path & ": replaced a pre-existing file whose " &
          "bytes this release does not preserve; left in place")
        continue
    removeOwned(f, result)
  removeEmptyDirs(byClass[lcDir])
  systemctlOrRecord(["daemon-reload"], result)

  # 5. State, keys, /etc/repro and the store. A mount still on the store
  #    (a stop that failed above) must not be deleted through. And an
  #    uninstall that left anything behind -- drift it would not remove, a
  #    step that failed -- keeps the state directory and with it the ledger
  #    copy, so the leftover stays identified and a second uninstall (after
  #    the operator restored or accepted the object) can finish the job.
  #    Only a complete reversal removes the state.
  when not mutated("uninstall-discards-state-on-drift"):
    if result.drift.len > 0 or result.errors.len > 0:
      result.errors.add("the add-on's state and ledger at " & stateDir &
        " are kept: the uninstall is incomplete (see the drift and errors " &
        "above); fix or accept them and run uninstall again")
      return
  for k in byClass[lcKey]:
    removeOwned(k, result)
  if dirExists(StoreRoot) and isMountPoint(StoreRoot):
    result.errors.add(StoreRoot & " is still mounted; the store is kept")
  elif not opts.keepStore:
    try:
      removeReproRoot()
      result.removed.add(ReproRoot)
    except OSError as ex:
      result.errors.add(ReproRoot & ": " & ex.msg)
  for root in ["/etc/repro", "/var/lib/repro", "/run/repro"]:
    if dirExists(root):
      try:
        removeDir(root)
        result.removed.add(root)
      except OSError as ex:
        result.errors.add(root & ": " & ex.msg)
