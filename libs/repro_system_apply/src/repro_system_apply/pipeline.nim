## B2: system-scope plan-apply-record pipeline.
##
## Lifts the home-profile contract from
## ``libs/repro_home_apply/src/repro_home_apply/pipeline.nim`` (which the
## ``Home-Profile-Generations-And-State.md`` spec documents in full) into
## system scope. Where the home-scope pipeline owns per-user launchers /
## managed blocks / resources, the system-scope pipeline owns the entire
## boot image: the kernel, the kernel cmdline, the systemd unit graph,
## the package closure, the user/group skeleton, the static mount layout.
## The shape (``plan``/``apply``/``record``) is the same.
##
## The flow:
##
##   1. ``planTransitions(prev, desired)`` computes a deterministic
##      ordered list of ``SystemTransition`` records from the previously
##      recorded ``SystemConfigManifest`` (or the empty manifest if this
##      is generation 1) to a new ``SystemConfig``.
##   2. ``applyTransitions(diff, ctx)`` walks the diff and materialises
##      every transition into the on-disk store: kernel + initrd +
##      cmdline in ``<state>/generations/<N>/boot/``, package realisation
##      symlinks in ``<state>/generations/<N>/packages/``, the rendered
##      ``/etc`` skeleton (``passwd`` + ``group`` + ``fstab`` + a
##      ``cmdline`` chunk) in ``<state>/generations/<N>/etc/``, and the
##      systemd unit-graph snapshot in
##      ``<state>/generations/<N>/systemd/``.
##   3. ``recordGeneration(applyResult, manifest)`` writes the
##      ``manifest.txt`` envelope into the new generation directory and
##      stages it via ``<state>/staged-next`` so the
##      ``reproos-confirm-generation`` unit can promote it to ``current``
##      on the next successful boot. The previous generation's pointer
##      stays as the fallback target referenced by GRUB's ``boot-prev``
##      entry.
##
## Compared with the home-profile pipeline, B2 deliberately keeps the
## following simplifications because they are not in scope for this
## milestone (and are explicitly deferred to B3 or later phases):
##
##   * No CAS-backed content addressing for the manifest itself. The
##     manifest is a plain UTF-8 ``manifest.txt`` file inside the
##     generation directory; the on-disk shape is documented inline
##     below. The home-scope ``RBPT`` framing + ``BLAKE3`` envelope is
##     the model to lift to in a later milestone when the CAS pivot
##     reaches system scope.
##   * No store GC. Generation directories live forever until B3 wires
##     ``reproos-rebuild gc``.
##   * No live ``systemctl daemon-reload`` invocations. The unit-graph
##     snapshot is staged, but the active reload happens on reboot
##     (or under B3's ``switch`` subcommand).
##   * Real realisation calls (kernel build, package downloads, foreign
##     bundle assembly) are stubbed in this milestone. The pipeline
##     records ``BuildEdge.payload`` into the manifest and emits a
##     ``packages/<name>`` placeholder file so the diff + the GRUB menu
##     generator have something to walk; B3 and Phase C replace the
##     stubs with the real adapter calls.
##
## The semantics of the public API are stable; the internals are what
## change in later milestones.
##
## ----------------------------------------------------------------------
## Risks called out in the B1 review (and how the B2 diff pass honours
## them):
##
##   * ``user "ada":`` redeclaration is **single-record replace** in the
##     DSL. The diff pass treats users keyed by name; a redeclaration
##     surfaces as one ``stChanged`` entry in category ``user``, never
##     as a per-field diff. (See ``diffUsers`` below.)
##   * Package name collision across tiers (a ``coreutils`` in Tier 1
##     replaced by a ``coreutils`` Tier 3 bundle) is **last-write-wins**
##     in the lowering pass; the diff pass surfaces a ``stChanged`` entry
##     and the ``detail`` field records the tier flip so the operator
##     sees ``"tier flipped: from-source -> foreign-bundle"`` in the
##     ``repro system plan`` output. (See ``diffPackages``.)
##   * ``EtcSkeleton`` is **optional**: a config with no users + no
##     mounts + no kernel cmdline emits no ``etc-skeleton`` edge. The
##     diff treats the absence as the empty skeleton.
##   * ``KernelCmdline`` is compared as a ``seq[string]`` (the parts
##     field), never as the space-joined render. The diff preserves
##     ordering: if the parts swap order without changing membership the
##     diff records ``stChanged`` with the per-position before/after
##     pair. (See ``diffKernelCmdline``.)
##
## ----------------------------------------------------------------------

import std/[algorithm, options, os, sequtils, strutils, tables, times]
from repro_core/paths import extendedPath

import ./errors
import ./locks
import ./lower
import ./types

export locks.SystemApplyLock, locks.acquireApplyLock,
       locks.releaseApplyLock, locks.applyLockPath,
       locks.DefaultLockTimeoutSeconds

# ---------------------------------------------------------------------------
# Diagnostic helper for the diff pass.
# ---------------------------------------------------------------------------

const
  ManifestFileName* = "manifest.txt"
    ## The per-generation manifest is written to
    ## ``<state>/generations/<N>/manifest.txt`` by
    ## ``recordGeneration``.
  StagedNextFileName* = "staged-next"
    ## ``<state>/staged-next`` records the generation number that is
    ## next-boot-target but not yet promoted. The
    ## ``reproos-confirm-generation.service`` unit clears it after a
    ## successful boot.
  CurrentSymlinkName* = "current"
    ## ``<state>/current`` — symbolic link (POSIX) or text file
    ## (Windows) that points at the **confirmed** active generation
    ## directory. New applies do not move this directly; the
    ## ``reproos-confirm-generation`` step does on next successful
    ## boot.
  GenerationsDirName* = "generations"

type
  # -------------------------------------------------------------------
  # Resource transitions. One per atomic apply step. The discriminator
  # ``kind`` selects an interpretation of ``before``/``after`` strings;
  # the categoriser ``category`` selects which pipeline executor handles
  # the transition.
  # -------------------------------------------------------------------

  SystemTransitionKind* = enum
    stAdded = "added"
    stRemoved = "removed"
    stChanged = "changed"

  SystemTransition* = object
    ## One row of the plan. The shape mirrors
    ## ``SystemConfigDiffEntry`` but adds ``detail`` (which the diff
    ## pass uses to record secondary context such as "tier flipped")
    ## and ``before``/``after`` byte previews.
    kind*: SystemTransitionKind
    category*: string                   ## ``"kernel"`` | ``"kernel-cmdline"``
                                        ## | ``"package"`` | ``"user"``
                                        ## | ``"service"`` | ``"mount"``
    key*: string                        ## name/path/identifier within
                                        ## the category
    before*: string                     ## previous value preview
                                        ## (empty when ``stAdded``)
    after*: string                      ## new value preview
                                        ## (empty when ``stRemoved``)
    detail*: string                     ## human-readable secondary
                                        ## context (e.g.
                                        ## ``"tier flipped: from-source -> foreign-bundle"``)

  SystemConfigDiff2* = object
    ## The full ordered transition list. Renamed from B1's
    ## ``SystemConfigDiff`` because the latter holds the AST-level
    ## byte preview; ``SystemConfigDiff2`` is the **apply-pass**
    ## transition list.
    transitions*: seq[SystemTransition]

  # -------------------------------------------------------------------
  # The recorded manifest — what B2 writes for a generation and what
  # B3 will consume to build a rollback plan. Symmetric to the home-
  # scope ActivationManifest from Home-Profile-Generations-And-State.md
  # but flattened into a text file (no CAS pivot yet, per the milestone
  # disclaimer above).
  # -------------------------------------------------------------------

  SystemConfigManifest* = ref object
    ## Recorded state of a generation. Two shapes are valid:
    ##
    ##   * the **empty** manifest, returned when no generation has been
    ##     applied yet (``generationNumber == 0``). The diff pass uses
    ##     this as the "from" side for the first apply.
    ##   * a populated manifest with the generation number + timestamp
    ##     + the canonical resource records.
    generationNumber*: int
    activationTimestamp*: int64         ## seconds since epoch; 0 in
                                        ## the empty manifest
    activationTimeIso*: string          ## ISO-8601 rendering for
                                        ## human-readable display; the
                                        ## diff hash is computed from
                                        ## the unix int (and recorded
                                        ## here only for display).
    kernel*: KernelRef
    kernelCmdline*: KernelCmdline
    packages*: seq[PackageRef]
    users*: seq[User]
    services*: seq[ServiceState]
    mounts*: seq[MountEntry]
    sourceConfigPath*: string           ## the absolute path to the
                                        ## ``configuration.nim`` that
                                        ## produced this generation;
                                        ## may be ``""`` for the empty
                                        ## manifest.
    buildGraphSerialized*: string       ## the
                                        ## ``serializeForReproCheck``
                                        ## output for the lowered
                                        ## graph; recorded so the next
                                        ## apply can re-derive the diff
                                        ## without re-parsing the prior
                                        ## ``configuration.nim``.

  # -------------------------------------------------------------------
  # ApplyContext / ApplyOptions — operator-visible knobs.
  # -------------------------------------------------------------------

  ApplyOptions* = object
    stateDir*: string                   ## ``""`` -> the default
                                        ## ``/var/lib/reproos`` (Linux)
                                        ## or a per-platform fallback
                                        ## (Windows uses
                                        ## ``%LOCALAPPDATA%\reproos``).
                                        ## Tests override this to drop
                                        ## a generation tree under a
                                        ## sandbox.
    bootDir*: string                    ## ``""`` -> ``/boot`` (Linux);
                                        ## tests override this to drop
                                        ## generated GRUB menus under a
                                        ## sandbox.
    runtimeDir*: string                 ## ``""`` -> ``/run/reproos`` on
                                        ## Linux. Tests override this
                                        ## to verify the staged-next
                                        ## flag.
    activationTimestamp*: int64         ## ``0`` -> ``getTime().toUnix``
    skipRealize*: bool                  ## true in unit tests; skips the
                                        ## stub realiser that would
                                        ## otherwise write placeholder
                                        ## ``packages/<name>`` files

  ApplyContext* = object
    ## Resolved options + the previous-generation manifest. Built by
    ## ``resolveApplyContext`` from ``ApplyOptions`` and the on-disk
    ## state directory.
    options*: ApplyOptions
    previousManifest*: SystemConfigManifest
    nextGenerationNumber*: int          ## the one this apply will write
    nextGenerationDir*: string          ## absolute path under
                                        ## ``<state>/generations/<N>``

  # -------------------------------------------------------------------
  # ApplyResult — what ``applyTransitions`` hands to
  # ``recordGeneration``.
  # -------------------------------------------------------------------

  ApplyResult* = object
    diff*: SystemConfigDiff2            ## the diff the executor walked
    transitionsExecuted*: int           ## how many transitions
                                        ## triggered an on-disk write
                                        ## (``stChanged``/``stAdded``/
                                        ## ``stRemoved`` all count)
    realizedKernel*: bool               ## true iff a kernel
                                        ## transition wrote into the
                                        ## generation's ``boot/`` dir
    realizedPackages*: seq[string]      ## the package names whose
                                        ## ``packages/<name>``
                                        ## placeholder was written
    wroteEtcSkeleton*: bool             ## true iff ``etc/passwd`` (or
                                        ## a sibling) was written
    wroteUnitGraph*: bool               ## true iff
                                        ## ``systemd/units.list`` was
                                        ## written
    isNoOp*: bool                       ## true iff the diff was empty
                                        ## (apply was a no-op)
    desiredManifest*: SystemConfigManifest
                                        ## the manifest that
                                        ## ``recordGeneration`` will
                                        ## persist

  # -------------------------------------------------------------------
  # GenerationManifest — alias of SystemConfigManifest with extra
  # bookkeeping fields populated by ``recordGeneration``.
  # -------------------------------------------------------------------

  GenerationManifest* = object
    ## What ``recordGeneration`` returns. Includes the manifest plus
    ## the on-disk paths the rebuild CLI reports back to the user and
    ## the GRUB menu generator consumes.
    manifest*: SystemConfigManifest
    generationDir*: string              ## absolute path of the
                                        ## generation directory
    manifestPath*: string               ## absolute path of the
                                        ## written ``manifest.txt``
    stagedNextPath*: string             ## absolute path of the
                                        ## ``<state>/staged-next``
                                        ## flag file
    bootDir*: string                    ## absolute path to the
                                        ## per-generation ``boot/``
                                        ## directory
    kernelPath*: string                 ## absolute path to the
                                        ## per-generation kernel
                                        ## placeholder
    initrdPath*: string                 ## absolute path to the
                                        ## per-generation initrd
                                        ## placeholder
    cmdlinePath*: string                ## absolute path to the
                                        ## per-generation cmdline
                                        ## file

# ---------------------------------------------------------------------------
# Empty-manifest helper.
# ---------------------------------------------------------------------------

proc newEmptyManifest*(): SystemConfigManifest =
  SystemConfigManifest(generationNumber: 0,
    activationTimestamp: 0,
    activationTimeIso: "")

proc isEmptyManifest*(m: SystemConfigManifest): bool =
  m.isNil or m.generationNumber == 0

# ---------------------------------------------------------------------------
# Helpers: previews for the diff.
# ---------------------------------------------------------------------------

proc previewKernel(k: KernelRef): string =
  if k.isEmpty: "" else: "kernel=" & k.name

proc previewKernelCmdline(c: KernelCmdline): string =
  ## The diff preview uses ``" | "`` as the field separator instead
  ## of the space the lowering pass uses to render the on-disk file,
  ## because a kernel cmdline part can contain a literal space (e.g.
  ## ``console=tty0 console=ttyS0``) — joining with ``" "`` makes the
  ## per-position before/after ambiguous in the preview. The
  ## reproducibility check still uses the lowering pass's space-join.
  if c.isEmpty: "" else: c.parts.join(" | ")

proc previewPackage(p: PackageRef): string =
  result = "pkg=" & p.name & " tier=" & $p.tier
  if p.distro.len > 0:
    result.add " distro=" & p.distro
  if p.snapshot.len > 0:
    result.add " snapshot=" & p.snapshot

proc previewUser(u: User): string =
  result = "user=" & u.name & " shell=" & u.shell
  if u.uid.isSome:
    result.add " uid=" & $u.uid.get
  if u.homeDir.len > 0:
    result.add " home=" & u.homeDir
  if u.groups.len > 0:
    var sortedGroups = u.groups
    sortedGroups.sort()
    result.add " groups=" & sortedGroups.join(",")
  if u.passwordHash.len > 0:
    result.add " pwh=" & u.passwordHash

proc previewService(s: ServiceState): string =
  "unit=" & s.unit & " state=" & $s.state

proc previewMount(m: MountEntry): string =
  result = "mp=" & m.mountPoint & " src=" & m.source & " fs=" & m.fstype
  if m.options.len > 0:
    var opts = m.options
    opts.sort()
    result.add " opts=" & opts.join(",")
  if m.dump != 0:
    result.add " dump=" & $m.dump
  if m.pass != 0:
    result.add " pass=" & $m.pass

# ---------------------------------------------------------------------------
# Plan-step diff helpers, one per category. Each takes the previous
# manifest's records + the new config's records, and appends ordered
# transitions to ``out_transitions``.
# ---------------------------------------------------------------------------

proc diffKernel(prev: KernelRef; cur: KernelRef;
                out_transitions: var seq[SystemTransition]) =
  if prev.isEmpty and cur.isEmpty: return
  if prev.isEmpty and not cur.isEmpty:
    out_transitions.add SystemTransition(kind: stAdded,
      category: "kernel", key: cur.name,
      before: "", after: previewKernel(cur))
  elif not prev.isEmpty and cur.isEmpty:
    out_transitions.add SystemTransition(kind: stRemoved,
      category: "kernel", key: prev.name,
      before: previewKernel(prev), after: "")
  elif prev.name != cur.name:
    out_transitions.add SystemTransition(kind: stChanged,
      category: "kernel", key: cur.name,
      before: previewKernel(prev),
      after: previewKernel(cur),
      detail: "kernel symbol changed: " & prev.name & " -> " & cur.name)

proc diffKernelCmdline(prev: KernelCmdline; cur: KernelCmdline;
                       out_transitions: var seq[SystemTransition]) =
  ## Compares the ``parts`` sequences position-by-position; surfaces a
  ## single ``stChanged`` entry per cmdline if the sequences differ.
  ## We never compare the space-joined render — the B1 review flagged
  ## that as ambiguous when a part contains a literal space.
  if prev.isEmpty and cur.isEmpty: return
  if prev.isEmpty and not cur.isEmpty:
    out_transitions.add SystemTransition(kind: stAdded,
      category: "kernel-cmdline", key: "default",
      before: "", after: previewKernelCmdline(cur),
      detail: "added " & $cur.parts.len & " cmdline parts")
    return
  if not prev.isEmpty and cur.isEmpty:
    out_transitions.add SystemTransition(kind: stRemoved,
      category: "kernel-cmdline", key: "default",
      before: previewKernelCmdline(prev), after: "",
      detail: "removed " & $prev.parts.len & " cmdline parts")
    return
  # Both populated; compare positions.
  if prev.parts == cur.parts: return
  var detailBits: seq[string]
  let maxLen = max(prev.parts.len, cur.parts.len)
  for i in 0 ..< maxLen:
    let p = if i < prev.parts.len: prev.parts[i] else: ""
    let c = if i < cur.parts.len: cur.parts[i] else: ""
    if p != c:
      detailBits.add "[" & $i & "] '" & p & "' -> '" & c & "'"
  out_transitions.add SystemTransition(kind: stChanged,
    category: "kernel-cmdline", key: "default",
    before: previewKernelCmdline(prev),
    after: previewKernelCmdline(cur),
    detail: detailBits.join("; "))

proc diffPackages(prev: seq[PackageRef]; cur: seq[PackageRef];
                  out_transitions: var seq[SystemTransition]) =
  ## Key by ``name``; the B1 lowering pass already deduplicates by
  ## name. The diff orders adds + removes + changes alphabetically so
  ## the on-disk transition list is deterministic.
  var byNamePrev = initOrderedTable[string, PackageRef]()
  var byNameCur = initOrderedTable[string, PackageRef]()
  for p in prev: byNamePrev[p.name] = p
  for p in cur: byNameCur[p.name] = p
  var allNames: seq[string]
  for n in byNamePrev.keys:
    if n notin allNames: allNames.add n
  for n in byNameCur.keys:
    if n notin allNames: allNames.add n
  allNames.sort()
  for n in allNames:
    let hadPrev = n in byNamePrev
    let hadCur = n in byNameCur
    if hadCur and not hadPrev:
      out_transitions.add SystemTransition(kind: stAdded,
        category: "package", key: n,
        before: "", after: previewPackage(byNameCur[n]))
    elif hadPrev and not hadCur:
      out_transitions.add SystemTransition(kind: stRemoved,
        category: "package", key: n,
        before: previewPackage(byNamePrev[n]), after: "")
    else:
      let pp = byNamePrev[n]
      let pc = byNameCur[n]
      if pp.tier != pc.tier or pp.distro != pc.distro or
         pp.snapshot != pc.snapshot:
        var detail = ""
        if pp.tier != pc.tier:
          detail = "tier flipped: " & $pp.tier & " -> " & $pc.tier
        elif pp.snapshot != pc.snapshot:
          detail = "snapshot changed: " & pp.snapshot & " -> " & pc.snapshot
        elif pp.distro != pc.distro:
          detail = "distro changed: " & pp.distro & " -> " & pc.distro
        out_transitions.add SystemTransition(kind: stChanged,
          category: "package", key: n,
          before: previewPackage(pp),
          after: previewPackage(pc),
          detail: detail)

proc diffUsers(prev: seq[User]; cur: seq[User];
               out_transitions: var seq[SystemTransition]) =
  ## Key by ``name``. A redeclaration in the DSL parser is a
  ## single-record REPLACE — the B1 parser's per-block handling makes
  ## sure ``parent.users`` contains exactly one entry per name. The
  ## diff therefore emits a single ``stChanged`` transition for any
  ## same-name pair whose fields differ; it never splits into
  ## per-field diff rows.
  var byNamePrev = initOrderedTable[string, User]()
  var byNameCur = initOrderedTable[string, User]()
  for u in prev: byNamePrev[u.name] = u
  for u in cur: byNameCur[u.name] = u
  var allNames: seq[string]
  for n in byNamePrev.keys:
    if n notin allNames: allNames.add n
  for n in byNameCur.keys:
    if n notin allNames: allNames.add n
  allNames.sort()
  for n in allNames:
    let hadPrev = n in byNamePrev
    let hadCur = n in byNameCur
    if hadCur and not hadPrev:
      out_transitions.add SystemTransition(kind: stAdded,
        category: "user", key: n,
        before: "", after: previewUser(byNameCur[n]))
    elif hadPrev and not hadCur:
      out_transitions.add SystemTransition(kind: stRemoved,
        category: "user", key: n,
        before: previewUser(byNamePrev[n]), after: "")
    else:
      let up = byNamePrev[n]
      let uc = byNameCur[n]
      if previewUser(up) != previewUser(uc):
        out_transitions.add SystemTransition(kind: stChanged,
          category: "user", key: n,
          before: previewUser(up),
          after: previewUser(uc),
          detail: "user redeclared")

proc diffServices(prev: seq[ServiceState]; cur: seq[ServiceState];
                  out_transitions: var seq[SystemTransition]) =
  var byUnitPrev = initOrderedTable[string, ServiceState]()
  var byUnitCur = initOrderedTable[string, ServiceState]()
  for s in prev: byUnitPrev[s.unit] = s
  for s in cur: byUnitCur[s.unit] = s
  var allUnits: seq[string]
  for u in byUnitPrev.keys:
    if u notin allUnits: allUnits.add u
  for u in byUnitCur.keys:
    if u notin allUnits: allUnits.add u
  allUnits.sort()
  for u in allUnits:
    let hadPrev = u in byUnitPrev
    let hadCur = u in byUnitCur
    if hadCur and not hadPrev:
      out_transitions.add SystemTransition(kind: stAdded,
        category: "service", key: u,
        before: "", after: previewService(byUnitCur[u]))
    elif hadPrev and not hadCur:
      out_transitions.add SystemTransition(kind: stRemoved,
        category: "service", key: u,
        before: previewService(byUnitPrev[u]), after: "")
    elif byUnitPrev[u].state != byUnitCur[u].state:
      out_transitions.add SystemTransition(kind: stChanged,
        category: "service", key: u,
        before: previewService(byUnitPrev[u]),
        after: previewService(byUnitCur[u]),
        detail: "state changed: " & $byUnitPrev[u].state & " -> " & $byUnitCur[u].state)

proc diffMounts(prev: seq[MountEntry]; cur: seq[MountEntry];
                out_transitions: var seq[SystemTransition]) =
  var byPointPrev = initOrderedTable[string, MountEntry]()
  var byPointCur = initOrderedTable[string, MountEntry]()
  for m in prev: byPointPrev[m.mountPoint] = m
  for m in cur: byPointCur[m.mountPoint] = m
  var allPoints: seq[string]
  for mp in byPointPrev.keys:
    if mp notin allPoints: allPoints.add mp
  for mp in byPointCur.keys:
    if mp notin allPoints: allPoints.add mp
  allPoints.sort()
  for mp in allPoints:
    let hadPrev = mp in byPointPrev
    let hadCur = mp in byPointCur
    if hadCur and not hadPrev:
      out_transitions.add SystemTransition(kind: stAdded,
        category: "mount", key: mp,
        before: "", after: previewMount(byPointCur[mp]))
    elif hadPrev and not hadCur:
      out_transitions.add SystemTransition(kind: stRemoved,
        category: "mount", key: mp,
        before: previewMount(byPointPrev[mp]), after: "")
    elif previewMount(byPointPrev[mp]) != previewMount(byPointCur[mp]):
      out_transitions.add SystemTransition(kind: stChanged,
        category: "mount", key: mp,
        before: previewMount(byPointPrev[mp]),
        after: previewMount(byPointCur[mp]),
        detail: "mount entry replaced")

# ---------------------------------------------------------------------------
# Public ``planTransitions``.
# ---------------------------------------------------------------------------

proc planTransitions*(prev: SystemConfigManifest;
                      desired: SystemConfig): SystemConfigDiff2 =
  ## Compute the ordered transition list between the previously
  ## recorded ``SystemConfigManifest`` and the new desired
  ## ``SystemConfig``. The result is deterministic: re-planning the
  ## same pair produces a byte-identical ``SystemConfigDiff2``.
  var transitions: seq[SystemTransition]
  let p = if prev.isNil: newEmptyManifest() else: prev
  diffKernel(p.kernel, desired.kernel, transitions)
  diffKernelCmdline(p.kernelCmdline, desired.kernelCmdline, transitions)
  diffPackages(p.packages, desired.packages, transitions)
  diffUsers(p.users, desired.users, transitions)
  diffServices(p.services, desired.services, transitions)
  diffMounts(p.mounts, desired.mounts, transitions)
  # Stable category ordering (kernel < kernel-cmdline < package < user
  # < service < mount) so the per-category diff sequences interleave
  # deterministically; we already build them in that order so no
  # further sort is needed.
  SystemConfigDiff2(transitions: transitions)

# ---------------------------------------------------------------------------
# Manifest serialization. Plain text; deterministic ordering.
# ---------------------------------------------------------------------------

proc serializeManifest*(m: SystemConfigManifest): string =
  ## Render ``m`` as a deterministic UTF-8 ``manifest.txt`` body. The
  ## same manifest always serialises to the same bytes; the rollback
  ## pass (B3) parses this back.
  var lines = newSeq[string](0)
  lines.add "schema = 1"
  lines.add "generation = " & $m.generationNumber
  lines.add "activationTimestamp = " & $m.activationTimestamp
  lines.add "activationTimeIso = " & m.activationTimeIso
  lines.add "sourceConfigPath = " & m.sourceConfigPath
  if not m.kernel.isEmpty:
    lines.add "kernel = " & m.kernel.name
  if not m.kernelCmdline.isEmpty:
    lines.add "kernel_cmdline.count = " & $m.kernelCmdline.parts.len
    for i, p in m.kernelCmdline.parts:
      lines.add "kernel_cmdline[" & $i & "] = " & p
  # Packages sorted by name.
  var pkgs = m.packages
  pkgs.sort(proc(a, b: PackageRef): int = cmp(a.name, b.name))
  lines.add "packages.count = " & $pkgs.len
  for p in pkgs:
    lines.add "package " & p.name & " tier=" & $p.tier &
      " distro=" & p.distro & " snapshot=" & p.snapshot
  # Users sorted by name.
  var users = m.users
  users.sort(proc(a, b: User): int = cmp(a.name, b.name))
  lines.add "users.count = " & $users.len
  for u in users:
    var gs = u.groups
    gs.sort()
    let uidStr = if u.uid.isSome: $u.uid.get else: ""
    lines.add "user " & u.name & " shell=" & u.shell &
      " uid=" & uidStr &
      " home=" & u.homeDir &
      " groups=" & gs.join(",") &
      " pwh=" & u.passwordHash
  # Services sorted by unit.
  var svcs = m.services
  svcs.sort(proc(a, b: ServiceState): int = cmp(a.unit, b.unit))
  lines.add "services.count = " & $svcs.len
  for s in svcs:
    lines.add "service " & s.unit & " state=" & $s.state
  # Mounts sorted by mount point.
  var mounts = m.mounts
  mounts.sort(proc(a, b: MountEntry): int = cmp(a.mountPoint, b.mountPoint))
  lines.add "mounts.count = " & $mounts.len
  for mp in mounts:
    var opts = mp.options
    opts.sort()
    let optStr = if opts.len > 0: opts.join(",") else: "defaults"
    lines.add "mount " & mp.mountPoint &
      " source=" & mp.source &
      " fstype=" & mp.fstype &
      " options=" & optStr &
      " dump=" & $mp.dump &
      " pass=" & $mp.pass
  lines.add "buildGraphSerialized.lines = " &
    $m.buildGraphSerialized.split('\n').len
  for ln in m.buildGraphSerialized.split('\n'):
    lines.add "buildGraph: " & ln
  lines.join("\n") & "\n"

# ---------------------------------------------------------------------------
# Manifest parser — reverse of ``serializeManifest`` for use by
# ``loadPreviousManifest``. Only the fields B2 + B3 need are parsed; a
# diagnostic in EBadManifest covers malformed input.
# ---------------------------------------------------------------------------

proc parseManifest*(body: string): SystemConfigManifest =
  ## Parse a serialised manifest. The format is the deterministic
  ## ``key = value`` shape ``serializeManifest`` emits. Lines starting
  ## with ``package ``/``user ``/``service ``/``mount `` carry a
  ## per-record record where the rest of the line is a sequence of
  ## ``<field>=<value>`` tokens space-separated; values do not contain
  ## spaces by construction (the lowering pass already sanitises them).
  result = newEmptyManifest()
  var graphLines: seq[string]
  var sawBuildGraphCountLine = false
  for rawLine in body.split('\n'):
    let line = rawLine.strip(trailing = true, chars = {'\r'})
    if line.len == 0: continue
    if line.startsWith("buildGraph: "):
      graphLines.add line["buildGraph: ".len .. ^1]
      continue
    let eqIdx = line.find('=')
    if eqIdx < 0:
      # Records carry no `=` on the left of the first space; the
      # following branches handle them.
      discard
    # Record-style lines.
    if line.startsWith("package "):
      let body2 = line["package ".len .. ^1]
      let spIdx = body2.find(' ')
      let name = if spIdx > 0: body2[0 ..< spIdx] else: body2
      var p = PackageRef(name: name)
      if spIdx > 0:
        for tok in body2[spIdx + 1 .. ^1].split(' '):
          let eq = tok.find('=')
          if eq < 0: continue
          let k = tok[0 ..< eq]
          let v = tok[eq + 1 .. ^1]
          case k
          of "tier":
            case v
            of $ptFromSource: p.tier = ptFromSource
            of $ptStandaloneBinary: p.tier = ptStandaloneBinary
            of $ptForeignBundle: p.tier = ptForeignBundle
            else: discard
          of "distro": p.distro = v
          of "snapshot": p.snapshot = v
          else: discard
      result.packages.add p
      continue
    if line.startsWith("user "):
      let body2 = line["user ".len .. ^1]
      let spIdx = body2.find(' ')
      let name = if spIdx > 0: body2[0 ..< spIdx] else: body2
      var u = User(name: name)
      if spIdx > 0:
        for tok in body2[spIdx + 1 .. ^1].split(' '):
          let eq = tok.find('=')
          if eq < 0: continue
          let k = tok[0 ..< eq]
          let v = tok[eq + 1 .. ^1]
          case k
          of "shell": u.shell = v
          of "uid":
            if v.len > 0:
              try: u.uid = some(parseInt(v))
              except ValueError: discard
          of "home": u.homeDir = v
          of "groups":
            if v.len > 0:
              for g in v.split(','):
                if g.len > 0: u.groups.add g
          of "pwh": u.passwordHash = v
          else: discard
      result.users.add u
      continue
    if line.startsWith("service "):
      let body2 = line["service ".len .. ^1]
      let spIdx = body2.find(' ')
      let unit = if spIdx > 0: body2[0 ..< spIdx] else: body2
      var st = ServiceState(unit: unit, state: svsEnabled)
      if spIdx > 0:
        for tok in body2[spIdx + 1 .. ^1].split(' '):
          let eq = tok.find('=')
          if eq < 0: continue
          let k = tok[0 ..< eq]
          let v = tok[eq + 1 .. ^1]
          case k
          of "state":
            case v
            of $svsEnabled: st.state = svsEnabled
            of $svsDisabled: st.state = svsDisabled
            of $svsMasked: st.state = svsMasked
            else: discard
          else: discard
      result.services.add st
      continue
    if line.startsWith("mount "):
      let body2 = line["mount ".len .. ^1]
      let spIdx = body2.find(' ')
      let mp = if spIdx > 0: body2[0 ..< spIdx] else: body2
      var entry = MountEntry(mountPoint: mp)
      if spIdx > 0:
        for tok in body2[spIdx + 1 .. ^1].split(' '):
          let eq = tok.find('=')
          if eq < 0: continue
          let k = tok[0 ..< eq]
          let v = tok[eq + 1 .. ^1]
          case k
          of "source": entry.source = v
          of "fstype": entry.fstype = v
          of "options":
            if v != "defaults" and v.len > 0:
              for o in v.split(','):
                if o.len > 0: entry.options.add o
          of "dump":
            try: entry.dump = parseInt(v)
            except ValueError: discard
          of "pass":
            try: entry.pass = parseInt(v)
            except ValueError: discard
          else: discard
      result.mounts.add entry
      continue
    # Scalar `key = value` lines.
    if eqIdx <= 0: continue
    let key = line[0 ..< eqIdx].strip()
    let val = line[eqIdx + 1 .. ^1].strip()
    case key
    of "schema": discard
    of "generation":
      try: result.generationNumber = parseInt(val)
      except ValueError: discard
    of "activationTimestamp":
      try: result.activationTimestamp = parseBiggestInt(val)
      except ValueError: discard
    of "activationTimeIso": result.activationTimeIso = val
    of "sourceConfigPath": result.sourceConfigPath = val
    of "kernel": result.kernel = KernelRef(name: val)
    of "kernel_cmdline.count":
      try:
        let n = parseInt(val)
        if n > 0:
          result.kernelCmdline = KernelCmdline(parts: newSeq[string](n))
      except ValueError: discard
    of "packages.count", "users.count", "services.count",
       "mounts.count", "buildGraphSerialized.lines":
      discard # informational; we count records inline.
    else:
      if key.startsWith("kernel_cmdline[") and key.endsWith("]"):
        let idxStr = key["kernel_cmdline[".len ..< key.len - 1]
        try:
          let idx = parseInt(idxStr)
          if idx >= 0 and idx < result.kernelCmdline.parts.len:
            result.kernelCmdline.parts[idx] = val
        except ValueError: discard
  if graphLines.len > 0:
    if sawBuildGraphCountLine:
      discard
    result.buildGraphSerialized = graphLines.join("\n")

# ---------------------------------------------------------------------------
# State-dir discovery + generation-number allocation.
# ---------------------------------------------------------------------------

proc defaultStateDir(): string =
  when defined(windows):
    let lad = getEnv("LOCALAPPDATA")
    if lad.len > 0: lad / "reproos"
    else: getHomeDir() / "reproos-state"
  else:
    "/var/lib/reproos"

proc defaultBootDir(): string =
  when defined(windows):
    let lad = getEnv("LOCALAPPDATA")
    if lad.len > 0: lad / "reproos" / "boot"
    else: getHomeDir() / "reproos-state" / "boot"
  else:
    "/boot"

proc defaultRuntimeDir(): string =
  when defined(windows):
    let lad = getEnv("LOCALAPPDATA")
    if lad.len > 0: lad / "reproos" / "runtime"
    else: getHomeDir() / "reproos-state" / "runtime"
  else:
    "/run/reproos"

proc generationsRoot*(stateDir: string): string =
  stateDir / GenerationsDirName

proc generationDirFor*(stateDir: string; number: int): string =
  generationsRoot(stateDir) / $number

proc stagedNextPathFor*(stateDir: string): string =
  stateDir / StagedNextFileName

proc currentPathFor*(stateDir: string): string =
  stateDir / CurrentSymlinkName

proc highestExistingGeneration*(stateDir: string): int =
  ## Scan ``<state>/generations/`` for integer-named directories. The
  ## generation number is the highest integer found; ``0`` if the
  ## directory is empty or absent.
  result = 0
  let root = generationsRoot(stateDir)
  if not dirExists(extendedPath(root)): return
  for kind, path in walkDir(extendedPath(root)):
    if kind != pcDir: continue
    let name = path.lastPathPart
    try:
      let n = parseInt(name)
      if n > result: result = n
    except ValueError:
      discard

proc loadPreviousManifest*(stateDir: string): SystemConfigManifest =
  ## Load the most recent generation's manifest (or return the empty
  ## manifest if no generation exists).
  let n = highestExistingGeneration(stateDir)
  if n == 0:
    return newEmptyManifest()
  let mp = generationDirFor(stateDir, n) / ManifestFileName
  if not fileExists(extendedPath(mp)):
    return newEmptyManifest()
  let body = readFile(extendedPath(mp))
  parseManifest(body)

# ---------------------------------------------------------------------------
# Build the new manifest from a parsed SystemConfig + the apply context.
# ---------------------------------------------------------------------------

proc buildDesiredManifest*(cfg: SystemConfig; ctx: ApplyContext): SystemConfigManifest =
  let ts = if ctx.options.activationTimestamp != 0:
    ctx.options.activationTimestamp
  else:
    getTime().toUnix
  let iso = try:
    fromUnix(ts).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  except CatchableError:
    ""
  let g = lower(cfg)
  SystemConfigManifest(generationNumber: ctx.nextGenerationNumber,
    activationTimestamp: ts,
    activationTimeIso: iso,
    kernel: cfg.kernel,
    kernelCmdline: cfg.kernelCmdline,
    packages: cfg.packages,
    users: cfg.users,
    services: cfg.services,
    mounts: cfg.mounts,
    sourceConfigPath: cfg.sourceFile,
    buildGraphSerialized: serializeForReproCheck(g))

# ---------------------------------------------------------------------------
# Resolve options + previous manifest.
# ---------------------------------------------------------------------------

proc resolveApplyContext*(cfg: SystemConfig; opts: ApplyOptions): ApplyContext =
  result.options = opts
  if result.options.stateDir.len == 0:
    result.options.stateDir = defaultStateDir()
  if result.options.bootDir.len == 0:
    result.options.bootDir = defaultBootDir()
  if result.options.runtimeDir.len == 0:
    result.options.runtimeDir = defaultRuntimeDir()
  result.previousManifest = loadPreviousManifest(result.options.stateDir)
  let prevN = if result.previousManifest.isEmptyManifest: 0
              else: result.previousManifest.generationNumber
  result.nextGenerationNumber = prevN + 1
  result.nextGenerationDir = generationDirFor(
    result.options.stateDir, result.nextGenerationNumber)

# ---------------------------------------------------------------------------
# Idempotency check: if the desired manifest matches the previous
# manifest's content (kernel + cmdline + packages + users + services +
# mounts), the apply is a no-op and the previous generation stays
# active.
# ---------------------------------------------------------------------------

proc manifestsAreEquivalent*(a, b: SystemConfigManifest): bool =
  ## Compare two manifests for "same content"; ignores
  ## generationNumber + activationTimestamp + activationTimeIso so a
  ## no-op apply does not produce a new generation. The
  ## ``buildGraphSerialized`` field IS compared because two configs
  ## that lower to the same graph have the same effect on the system.
  if a.isNil or b.isNil: return false
  if a.buildGraphSerialized != b.buildGraphSerialized: return false
  # Defence in depth: compare the source AST too.
  if a.kernel.name != b.kernel.name: return false
  if a.kernelCmdline.parts != b.kernelCmdline.parts: return false
  if a.packages.len != b.packages.len: return false
  if a.users.len != b.users.len: return false
  if a.services.len != b.services.len: return false
  if a.mounts.len != b.mounts.len: return false
  true

# ---------------------------------------------------------------------------
# Apply executor: writes the on-disk per-generation tree.
# ---------------------------------------------------------------------------

proc ensureDir(path: string) =
  if not dirExists(extendedPath(path)):
    createDir(extendedPath(path))

proc writeFileText(path, content: string) =
  ensureDir(parentDir(path))
  writeFile(extendedPath(path), content)

proc renderEtcPasswd(users: seq[User]): string =
  var u = users
  u.sort(proc(a, b: User): int = cmp(a.name, b.name))
  var lines: seq[string]
  for entry in u:
    let uidStr = if entry.uid.isSome: $entry.uid.get else: ""
    let home = if entry.homeDir.len > 0: entry.homeDir
               elif entry.name == "root": "/root"
               else: "/home/" & entry.name
    let shellAbs = "/usr/bin/" & entry.shell
    lines.add entry.name & ":x:" & uidStr & "::" & home & ":" & shellAbs
  lines.join("\n") & (if lines.len > 0: "\n" else: "")

proc renderEtcGroup(users: seq[User]): string =
  var collected = initOrderedTable[string, seq[string]]()
  for u in users:
    for g in u.groups:
      if g notin collected:
        collected[g] = @[]
      collected[g].add u.name
  var groupNames = toSeq(collected.keys)
  groupNames.sort()
  var lines: seq[string]
  for g in groupNames:
    var members = collected[g]
    members.sort()
    lines.add g & ":x::" & members.join(",")
  lines.join("\n") & (if lines.len > 0: "\n" else: "")

proc renderEtcFstab(mounts: seq[MountEntry]): string =
  var sorted = mounts
  sorted.sort(proc(a, b: MountEntry): int = cmp(a.mountPoint, b.mountPoint))
  var lines: seq[string]
  for m in sorted:
    var opts = m.options
    opts.sort()
    let optStr = if opts.len > 0: opts.join(",") else: "defaults"
    lines.add m.source & "\t" & m.mountPoint & "\t" & m.fstype & "\t" &
      optStr & "\t" & $m.dump & "\t" & $m.pass
  lines.join("\n") & (if lines.len > 0: "\n" else: "")

proc renderUnitsList(services: seq[ServiceState]): string =
  var sorted = services
  sorted.sort(proc(a, b: ServiceState): int = cmp(a.unit, b.unit))
  var lines: seq[string]
  for s in sorted:
    lines.add s.unit & " " & $s.state
  lines.join("\n") & (if lines.len > 0: "\n" else: "")

proc renderKernelCmdline(c: KernelCmdline): string =
  ## Space-joined render of the cmdline parts. We deliberately preserve
  ## the seq (B1 review risk #4) — repro-check serialisation walks the
  ## seq directly via ``serializeForReproCheck``.
  c.parts.join(" ") & (if c.parts.len > 0: "\n" else: "")

proc applyTransitions*(diff: SystemConfigDiff2;
                      ctx: ApplyContext;
                      desired: SystemConfigManifest): ApplyResult =
  ## Execute the diff against ``ctx``. For each transition the
  ## executor writes the corresponding output under
  ## ``<state>/generations/<N>/`` so the recorded generation is a
  ## self-contained tree on disk.
  ##
  ## Idempotency: re-running ``applyTransitions`` with the same diff
  ## (and the same ``ctx`` pointing at the same generation directory)
  ## is a no-op — writes are full overwrites of file content, not
  ## appends.
  result.diff = diff
  result.desiredManifest = desired
  result.isNoOp = diff.transitions.len == 0
  if result.isNoOp:
    return
  let genDir = ctx.nextGenerationDir
  ensureDir(genDir)
  let bootDir = genDir / "boot"
  let etcDir = genDir / "etc"
  let pkgDir = genDir / "packages"
  let sysDir = genDir / "systemd"
  # Kernel: write a placeholder vmlinuz + initrd in boot/. (Real
  # realisation deferred to B3 + Phase R8.) We only create boot/ when
  # the desired config has a kernel.
  if not desired.kernel.isEmpty:
    ensureDir(bootDir)
    writeFileText(bootDir / "vmlinuz",
      "kernel-placeholder: " & desired.kernel.name & "\n")
    writeFileText(bootDir / "initrd.img",
      "initrd-placeholder: " & desired.kernel.name & "\n")
    result.realizedKernel = true
  # Cmdline.
  if not desired.kernelCmdline.isEmpty:
    ensureDir(bootDir)
    writeFileText(bootDir / "cmdline",
      renderKernelCmdline(desired.kernelCmdline))
  # Packages.
  if desired.packages.len > 0:
    ensureDir(pkgDir)
  for p in desired.packages:
    let target = pkgDir / p.name
    var body = "tier=" & $p.tier & "\n"
    if p.distro.len > 0: body.add "distro=" & p.distro & "\n"
    if p.snapshot.len > 0: body.add "snapshot=" & p.snapshot & "\n"
    if not ctx.options.skipRealize:
      writeFileText(target, body)
    result.realizedPackages.add p.name
  # /etc skeleton. The skeleton edge is omitted entirely when the
  # config has no users, no mounts, AND no kernel cmdline — this
  # mirrors B1's lowering pass (etc-skeleton edge omitted) and the
  # B1 review's risk #3 noted that B2 must handle the absence.
  let hasSkeleton = desired.users.len > 0 or desired.mounts.len > 0 or
                    not desired.kernelCmdline.isEmpty
  if hasSkeleton:
    ensureDir(etcDir)
    writeFileText(etcDir / "passwd", renderEtcPasswd(desired.users))
    writeFileText(etcDir / "group", renderEtcGroup(desired.users))
    writeFileText(etcDir / "fstab", renderEtcFstab(desired.mounts))
    if not desired.kernelCmdline.isEmpty:
      writeFileText(etcDir / "kernel-cmdline.parts",
        desired.kernelCmdline.parts.join("\n") & "\n")
    result.wroteEtcSkeleton = true
  # Systemd unit graph.
  if desired.services.len > 0:
    ensureDir(sysDir)
    writeFileText(sysDir / "units.list",
      renderUnitsList(desired.services))
    result.wroteUnitGraph = true
  for t in diff.transitions:
    if t.kind != stAdded or true:
      inc result.transitionsExecuted

# ---------------------------------------------------------------------------
# Record step: persist the manifest + flag the staged-next generation.
# ---------------------------------------------------------------------------

proc recordGeneration*(applyResult: ApplyResult;
                       ctx: ApplyContext): GenerationManifest =
  ## Persist the manifest into ``<state>/generations/<N>/manifest.txt``
  ## and stage the new generation via ``<state>/staged-next``. On
  ## next-successful-boot ``reproos-confirm-generation`` rotates
  ## ``<state>/current`` to point at it.
  result.manifest = applyResult.desiredManifest
  result.generationDir = ctx.nextGenerationDir
  result.manifestPath = result.generationDir / ManifestFileName
  result.stagedNextPath = stagedNextPathFor(ctx.options.stateDir)
  result.bootDir = result.generationDir / "boot"
  result.kernelPath = result.bootDir / "vmlinuz"
  result.initrdPath = result.bootDir / "initrd.img"
  result.cmdlinePath = result.bootDir / "cmdline"
  if applyResult.isNoOp:
    return
  ensureDir(result.generationDir)
  writeFile(extendedPath(result.manifestPath),
    serializeManifest(applyResult.desiredManifest))
  ensureDir(ctx.options.stateDir)
  writeFile(extendedPath(result.stagedNextPath),
    $applyResult.desiredManifest.generationNumber & "\n")

# ---------------------------------------------------------------------------
# Confirm-generation step — promotes the staged generation to
# ``current`` and clears ``staged-next``. Called by the
# ``reproos-confirm-generation.service`` systemd unit after a
# successful boot. Exposed publicly so the integration tests can
# simulate the boot promotion without a real reboot.
# ---------------------------------------------------------------------------

proc rotateCurrentPointer*(stateDir: string; genDir: string;
                           generationNumber: int) =
  ## B3 P2 risk #3: flip the ``<state>/current`` pointer atomically.
  ##
  ## On POSIX:
  ##   1. Create a temp symlink ``<state>/current.tmp`` pointing at
  ##      ``genDir``.
  ##   2. ``moveFile`` it onto the final ``<state>/current`` path —
  ##      ``rename(2)`` is atomic on the same filesystem, so a crash
  ##      mid-rotation never leaves the system without a ``current``
  ##      pointer (it either still points at the old generation or it
  ##      now points at the new one).
  ##   3. Fall back to a plain text file if symlink creation fails
  ##      (e.g. unprivileged user on a filesystem that forbids symlinks).
  ##
  ## On Windows we keep B2's text-file shape: the body is the absolute
  ## generation directory path. Windows ``MoveFileExW`` with
  ## ``MOVEFILE_REPLACE_EXISTING`` is the atomic equivalent the
  ## ``moveFile`` standard-lib wrapper invokes for us.
  ensureDir(stateDir)
  let curPath = currentPathFor(stateDir)
  let tmpPath = curPath & ".tmp"
  # Clean up any stale temp pointer from a prior crash.
  if symlinkExists(extendedPath(tmpPath)) or
     fileExists(extendedPath(tmpPath)):
    try: removeFile(extendedPath(tmpPath))
    except OSError: discard
  when defined(windows):
    writeFile(extendedPath(tmpPath), genDir & "\n")
    if fileExists(extendedPath(curPath)):
      try: removeFile(extendedPath(curPath))
      except OSError: discard
    moveFile(extendedPath(tmpPath), extendedPath(curPath))
  else:
    var madeSymlink = false
    try:
      createSymlink(extendedPath(genDir), extendedPath(tmpPath))
      madeSymlink = true
    except OSError:
      madeSymlink = false
    if madeSymlink:
      # POSIX `rename(2)` over an existing symlink is atomic — no need
      # to remove the old `current` first.
      try:
        moveFile(extendedPath(tmpPath), extendedPath(curPath))
      except OSError:
        # Fall through to text-file fallback.
        if symlinkExists(extendedPath(tmpPath)) or
           fileExists(extendedPath(tmpPath)):
          try: removeFile(extendedPath(tmpPath))
          except OSError: discard
        madeSymlink = false
    if not madeSymlink:
      writeFile(extendedPath(tmpPath), genDir & "\n")
      if symlinkExists(extendedPath(curPath)) or
         fileExists(extendedPath(curPath)):
        try: removeFile(extendedPath(curPath))
        except OSError: discard
      moveFile(extendedPath(tmpPath), extendedPath(curPath))
  discard generationNumber  # carried for diagnostics; no-op here.

proc confirmStagedGeneration*(stateDir: string): tuple[
    promoted: bool, generationNumber: int] =
  ## Flip ``<state>/current`` to the staged generation's directory and
  ## clear ``<state>/staged-next``. If no staged generation is
  ## flagged, this is a no-op.
  let stagedPath = stagedNextPathFor(stateDir)
  if not fileExists(extendedPath(stagedPath)):
    return (promoted: false, generationNumber: 0)
  let raw = readFile(extendedPath(stagedPath)).strip()
  let n = try: parseInt(raw)
          except ValueError: 0
  if n <= 0:
    removeFile(extendedPath(stagedPath))
    return (promoted: false, generationNumber: 0)
  let genDir = generationDirFor(stateDir, n)
  if not dirExists(extendedPath(genDir)):
    removeFile(extendedPath(stagedPath))
    return (promoted: false, generationNumber: 0)
  rotateCurrentPointer(stateDir, genDir, n)
  removeFile(extendedPath(stagedPath))
  (promoted: true, generationNumber: n)

type
  RepairKind* = enum
    rrkPartial = "partial-apply"   ## directory exists but manifest.txt
                                    ## is missing — apply crashed between
                                    ## creating the gen dir and writing
                                    ## the manifest.
    rrkMalformed = "malformed"     ## manifest.txt exists but does not
                                    ## parse (or carries no generation
                                    ## number).
    rrkOrphanStaged = "orphan-staged"
                                    ## staged-next records a generation
                                    ## number whose on-disk directory is
                                    ## missing — typically a partial
                                    ## ``recordGeneration``.

  RepairFinding* = object
    ## One row of the ``repairPartialApply`` report. ``removed`` is true
    ## when the sweep dropped the offending directory or stale flag;
    ## ``detail`` carries operator-visible context.
    kind*: RepairKind
    generationNumber*: int
    path*: string
    removed*: bool
    detail*: string

  RepairResult* = object
    findings*: seq[RepairFinding]
    removedCount*: int

proc isLikelyIncompleteGenerationDir(p: string): bool =
  ## Heuristic: a "partial" generation dir is one whose ``manifest.txt``
  ## file is missing. We deliberately do NOT delete a generation that
  ## merely has a sub-tree we don't understand — only the missing
  ## manifest tells us the apply was interrupted mid-write.
  not fileExists(extendedPath(p / ManifestFileName))

proc isManifestParsable(path: string): bool =
  if not fileExists(extendedPath(path)): return false
  try:
    let body = readFile(extendedPath(path))
    let m = parseManifest(body)
    return m.generationNumber > 0
  except CatchableError:
    return false

proc repairPartialApply*(stateDir: string;
                        dryRun = false): RepairResult =
  ## B3 P2 risk #4 + risk #5: walk ``<state>/generations/<N>/`` and
  ## drop any half-written directories (no ``manifest.txt`` = crashed
  ## mid-apply; manifest present but unparsable = malformed). The sweep
  ## is idempotent — running it twice on a clean state directory is a
  ## no-op.
  ##
  ## ``dryRun = true`` reports what would be removed without touching
  ## the filesystem; the CLI ``reproos-rebuild repair --dry-run`` flag
  ## maps onto this.
  let root = generationsRoot(stateDir)
  if not dirExists(extendedPath(root)):
    return
  for kind, path in walkDir(extendedPath(root)):
    if kind != pcDir: continue
    let name = path.lastPathPart
    var n: int
    try: n = parseInt(name)
    except ValueError: continue
    let manifestPath = path / ManifestFileName
    if isLikelyIncompleteGenerationDir(path):
      var finding = RepairFinding(kind: rrkPartial,
        generationNumber: n, path: path,
        detail: "manifest.txt missing — apply crashed mid-write")
      if not dryRun:
        try:
          removeDir(extendedPath(path))
          finding.removed = true
          inc result.removedCount
        except OSError as e:
          finding.detail.add " (removal failed: " & e.msg & ")"
      result.findings.add finding
      continue
    if not isManifestParsable(manifestPath):
      var finding = RepairFinding(kind: rrkMalformed,
        generationNumber: n, path: path,
        detail: "manifest.txt failed to parse")
      if not dryRun:
        try:
          removeDir(extendedPath(path))
          finding.removed = true
          inc result.removedCount
        except OSError as e:
          finding.detail.add " (removal failed: " & e.msg & ")"
      result.findings.add finding
  # Orphan staged-next: the staged flag references a directory that
  # vanished (e.g. operator wiped <state>/generations/<N>/ manually).
  let stagedPath = stagedNextPathFor(stateDir)
  if fileExists(extendedPath(stagedPath)):
    let raw = readFile(extendedPath(stagedPath)).strip()
    let n = try: parseInt(raw) except ValueError: 0
    if n > 0:
      let genDir = generationDirFor(stateDir, n)
      if not dirExists(extendedPath(genDir)) or
         not fileExists(extendedPath(genDir / ManifestFileName)):
        var finding = RepairFinding(kind: rrkOrphanStaged,
          generationNumber: n, path: stagedPath,
          detail: "staged-next points at " & genDir &
            " but the generation is missing or malformed")
        if not dryRun:
          try:
            removeFile(extendedPath(stagedPath))
            finding.removed = true
            inc result.removedCount
          except OSError as e:
            finding.detail.add " (removal failed: " & e.msg & ")"
        result.findings.add finding

proc readCurrentGeneration*(stateDir: string): int =
  ## Returns the confirmed-current generation number, or 0 if no
  ## generation is currently confirmed.
  let curPath = currentPathFor(stateDir)
  if not fileExists(extendedPath(curPath)):
    return 0
  let body = readFile(extendedPath(curPath)).strip()
  let last = body.lastPathPart
  try: parseInt(last)
  except ValueError: 0

# ---------------------------------------------------------------------------
# Top-level helper: ``planApplyRecord`` — runs the full pipeline.
# ---------------------------------------------------------------------------

proc planApplyRecord*(cfg: SystemConfig;
                     opts: ApplyOptions): GenerationManifest =
  ## Full plan-apply-record cycle. Returns the
  ## ``GenerationManifest`` describing the newly recorded generation.
  ## If the apply is a no-op (the desired manifest matches the
  ## previous one), the returned record has
  ## ``manifest.generationNumber == previous.generationNumber`` and
  ## ``manifestPath`` points at the previous manifest.
  ##
  ## B3 P2 risk #1: wraps the whole apply in the system apply lock so
  ## concurrent invocations are mutually exclusive. The default
  ## 30 s timeout matches the home-scope contract; raise
  ## ``ESystemApplyBusy`` on contention.
  ##
  ## B3 P2 risk #4: lazily reaps any half-written generation
  ## directories before computing ``nextGenerationNumber`` so a prior
  ## crash mid-apply cannot leak a stale slot that biases the next
  ## generation number.
  # Resolve the state directory eagerly so we can take the lock against
  # the same path the rest of the pipeline writes into.
  var resolvedOpts = opts
  if resolvedOpts.stateDir.len == 0:
    resolvedOpts.stateDir = defaultStateDir()
  var lock = acquireApplyLock(resolvedOpts.stateDir)
  try:
    discard repairPartialApply(resolvedOpts.stateDir, dryRun = false)
    var ctx = resolveApplyContext(cfg, resolvedOpts)
    let desired = buildDesiredManifest(cfg, ctx)
    # Idempotency check against the previous manifest.
    if manifestsAreEquivalent(ctx.previousManifest, desired):
      var noop: ApplyResult
      noop.diff = SystemConfigDiff2(transitions: @[])
      noop.isNoOp = true
      noop.desiredManifest = ctx.previousManifest
      # Re-point at the previous generation; do NOT bump the number.
      ctx.nextGenerationNumber = ctx.previousManifest.generationNumber
      ctx.nextGenerationDir = generationDirFor(
        ctx.options.stateDir, ctx.nextGenerationNumber)
      return recordGeneration(noop, ctx)
    let diff = planTransitions(ctx.previousManifest, cfg)
    let applied = applyTransitions(diff, ctx, desired)
    return recordGeneration(applied, ctx)
  finally:
    releaseApplyLock(lock)
