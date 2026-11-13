## Gate ``e2e_arch_testbed_is_pinned``.
##
## The Arch test bed (``arch_testbed.nim``) is reproducible from its pins:
##
## 1. **Two independent builds.** Each Arch guest of the selection
##    (default: the btrfs guest, the ext4 guest and the old-systemd
##    refusal fixture) is built twice from the pins alone, in this run's
##    own directory, and never from the cache: two fresh downloads-to-image
##    paths that share only the verified cloud image and the Arch Linux
##    Archive. A guest is then booted over each build through the path every
##    Arch gate uses (``prepareArchGuest``), and the two ``pacman -Q``
##    listings must be identical.
## 2. **``pacman -Syu`` is a no-op** on a fresh guest of every build:
##    exit 0, pacman's own "there is nothing to do", no package newer than
##    the pinned repositories, ``pacman -Q`` unchanged.
## 3. **Vacuity guards.** ``findmnt -no FSTYPE /`` is ``btrfs`` on the
##    btrfs guest and ``ext4`` on the ext4 guest; the old-systemd fixture's
##    PID 1 reports a systemd major below 258 (the add-on's matrix, spec
##    §6.1), so it is the refusal case it is meant to be.
## 4. **The cache.** A guest over the cached image every other Arch gate
##    boots (built now when missing) lists the same packages.
## 5. **Negative controls**, each refused by the test bed before any gate
##    could run, by the same acquisition path: a btrfs guest whose mirror
##    list names a live mirror (``geo.mirror.pkgbuild.com``), and one whose
##    ``pacman.conf`` adds a repository served by a live mirror while the
##    mirror list stays pinned. Each disk is made from build A, shut down,
##    flattened and booted again as a new guest; ``prepareArchGuest`` must
##    raise, naming the server.
##
## *Not covered yet:* the Omarchy VM's half of the gate (its two builds,
## its ``BUILD_ID``, its ``pacman -Syu`` under
## ``OMARCHY_ALLOW_DIRECT_PACMAN=1``, and the refusal of a pacman
## configuration naming anything but the capture cache). The Omarchy VM is
## not built yet; the record says so in ``omarchy``.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_arch_testbed_is_pinned``).
## Bases: ``REPRO_ADDON_BASES`` (Arch names only).
##
## *Mocking.* None: the real Arch Linux cloud image, real pacman against
## the real Arch Linux Archive, real QEMU guests.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./arch_testbed

const
  LiveMirror = "https://geo.mirror.pkgbuild.com/$repo/os/$arch"
  LiveRepoConf = "\n[testbed-live]\nServer = https://geo.mirror.pkgbuild.com/extra/os/$arch\n"

type GuestFacts = object
  fsType: string
  packages: string
  syu: SyuReport
  systemd: string

proc selection(): seq[BaseImage] =
  if getEnv("REPRO_ADDON_BASES").len == 0:
    for b in ArchBases: result.add(b)
  else:
    result = selectedArchBases()

proc observe(b: BaseImage; image: string; note: var seq[string]): GuestFacts =
  ## Boot a fresh guest of ``b`` over ``image`` the way every Arch gate
  ## does, and read what the gate compares.
  var g: Guest
  try:
    g = newArchGuestOver(b, image)
    g.boot()
    g.prepareArchGuest()
    result.fsType = g.rootFsType()
    result.systemd = g.run("systemctl --version | head -n 1").strip()
    result.packages = g.packageList()
    result.syu = g.syuReport()
  finally:
    if g != nil:
      note.add(g.log)
      g.destroy()

proc refusedAfter(b: BaseImage; image, workDir, tag, edit: string;
                  note: var seq[string]): tuple[refused: bool; detail: string] =
  ## Make a disk from ``image`` with ``edit`` applied, then acquire a new
  ## guest over it: the acquisition must refuse it.
  var g, h: Guest
  let disk = workDir / (tag & ".qcow2")
  try:
    g = newArchGuestOver(b, image)
    g.boot()
    g.prepareArchGuest()         # pinned before the edit
    discard g.run(edit)
    g.shutdown()
    convertTo(g.diskPath, disk)
    g.destroy()
    g = nil
    h = newArchGuestOver(b, disk)
    h.boot()
    try:
      h.prepareArchGuest()
      result = (false, "the test bed accepted it")
    except TestBedError as e:
      result = (true, e.msg)
  finally:
    for x in [g, h]:
      if x != nil:
        note.add(x.log)
        x.destroy()
    removeFile(disk)

suite "e2e_arch_testbed_is_pinned":
  test "two builds of every Arch guest agree, -Syu is a no-op, an unpinned pacman is refused":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_arch_testbed_is_pinned)")
    elif useIncus():
      skip("the Arch test bed boots disk images; QEMU only")
    else:
      let record = archRecordBase()
      record["gate"] = %"e2e_arch_testbed_is_pinned"
      record["reprobuild"] = %gitHead()
      record["backend"] = %"qemu"
      record["started"] = %($now().utc)
      record["omarchy"] = %("not covered: the Omarchy VM is not built yet " &
        "(AR1 open question: which Omarchy version is pinned and what its " &
        "installer is)")
      var failures: seq[string]
      var notes: seq[string]
      let builds = newJArray()
      let checks = newJArray()
      proc verify(name: string; ok: bool; detail: string) =
        checks.add(%*{"check": name, "ok": ok, "detail": detail})
        if not ok: failures.add(name & ": " & detail)
      let (work, token) = claimRunDir(QemuNamePrefix & "pin-" &
        $getCurrentProcessId() & "-" & randomHex(6))
      try:
        let sel = selection()
        var needBtrfs = false
        for b in sel:
          if archVariantOf(b) != avBtrfs: needBtrfs = true
        var btrfsOf: array[2, string]
        for round in 0 .. 1:
          let r = ["A", "B"][round]
          # The btrfs build of this round is the source of its ext4 and
          # old-systemd builds, so the rounds share nothing but the pins.
          var wanted: seq[ArchVariant]
          for b in sel: wanted.add(archVariantOf(b))
          if needBtrfs: wanted.add(avBtrfs)
          for v in [avBtrfs, avExt4, avOldSystemd]:
            if v notin wanted: continue
            let path = work / ($v & "-" & r & ".qcow2")
            let bi = buildArchImage(v, path, btrfsImage = btrfsOf[round])
            notes.add(bi.log)
            if v == avBtrfs: btrfsOf[round] = path
            builds.add(%*{"variant": $v, "round": r, "sha256": bi.sha256,
              "seconds": bi.seconds, "started": bi.startedAt,
              "finished": bi.finishedAt, "pinSet": bi.pinSet})
        for b in sel:
          let v = archVariantOf(b)
          var facts: array[2, GuestFacts]
          for round in 0 .. 1:
            let r = ["A", "B"][round]
            facts[round] = observe(b, work / ($v & "-" & r & ".qcow2"), notes)
            let f = facts[round]
            let wantFs = if v == avExt4: "ext4" else: "btrfs"
            verify(b.name & " build " & r & ": root filesystem is " & wantFs,
                  f.fsType == wantFs, f.fsType)
            verify(b.name & " build " & r & ": pacman -Syu is a no-op",
                  f.syu.noop, f.syu.detail & "\n" & f.syu.output)
            if v == avOldSystemd:
              var major = 0
              let parts = f.systemd.splitWhitespace()
              if parts.len >= 2:
                try: major = parseInt(parts[1]) except ValueError: discard
              verify(b.name & " build " & r & ": PID 1 is systemd below 258",
                    major > 0 and major < 258, f.systemd)
          verify(b.name & ": the two builds list the same packages",
                facts[0].packages == facts[1].packages,
                "A " & $facts[0].packages.countLines() & " lines, B " &
                $facts[1].packages.countLines() & " lines")
          record[b.name] = %*{"packages": facts[0].packages,
            "packageCount": facts[0].packages.strip().countLines(),
            "systemd": facts[0].systemd, "rootFs": facts[0].fsType,
            "syuA": facts[0].syu.output, "syuB": facts[1].syu.output}
          # 4. The cached image the other Arch gates boot.
          let cachedAt = now().utc
          let cached = observe(b, archGoldenImage(v), notes)
          verify(b.name & ": the cached image lists the same packages",
                cached.packages == facts[0].packages,
                "cached image " & archImageDir(v) & ", read " & $cachedAt)
          verify(b.name & " cached image: pacman -Syu is a no-op",
                cached.syu.noop, cached.syu.detail)
        # 5. Negative controls.
        if btrfsOf[0].len > 0:
          let live = refusedAfter(ArchBtrfs, btrfsOf[0], work, "live-mirrorlist",
            "printf '%s\\n' " & quoteShell("Server = " & LiveMirror) &
            " > /etc/pacman.d/mirrorlist", notes)
          verify("negative control: a live mirror in the mirror list is refused",
                live.refused and "geo.mirror.pkgbuild.com" in live.detail,
                live.detail)
          let extra = refusedAfter(ArchBtrfs, btrfsOf[0], work, "live-repo",
            "printf '%s' " & quoteShell(LiveRepoConf) & " >> /etc/pacman.conf",
            notes)
          verify("negative control: a live-mirror repository in pacman.conf " &
                "is refused", extra.refused and "testbed-live" in extra.detail,
                extra.detail)
          record["negativeControls"] = %*{"liveMirrorlist": live.detail,
                                          "liveRepository": extra.detail}
      except CatchableError as e:
        failures.add("exception: " & e.msg)
      finally:
        record["builds"] = builds
        record["checks"] = checks
        record["log"] = %notes
        try: releaseRunDir(work, token)
        except CatchableError as e: failures.add("teardown: " & e.msg)
      record["verdict"] = %(if failures.len == 0: "green" else: "red")
      record["finished"] = %($now().utc)
      echo "record: ", writeRecord("e2e_arch_testbed_is_pinned", record)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
