## Does a published install mirror survive being restored somewhere else?
##
## An install mirror is built under one checkout, published to a cache, and
## restored under a DIFFERENT checkout — usually on a different machine. Two
## fields of every ELF it ships decide whether it survives that move, and they
## fail in ways that look nothing alike:
##
## * ``PT_INTERP`` is resolved by the kernel before the process exists. A stale
##   one makes ``execve`` fail with ENOENT, which a shell reports as exit 127
##   on a file that is plainly sitting there. Nothing names the package and
##   nothing names the path.
## * ``DT_RUNPATH`` / ``DT_RPATH`` are searched by the loader, which silently
##   skips a directory that is not there. The tool starts, most of it works,
##   and only the code paths that touch the missing library fail — so a
##   per-module import error is the first symptom, long after the artifact was
##   accepted.
##
## Underneath they are one defect: an absolute path that named the PRODUCER's
## checkout. This module answers, for one path, whether it survives the move
## and where it moves to; ``auditInstallMirrorRelocatability`` asks that of
## every ELF in a mirror.
##
## The classifier is deliberately PURE — path arithmetic, no filesystem. What
## exists on disk is a different question with a different answer on every
## host, and mixing the two is how "it worked where I ran it" becomes a
## publication.

import std/[os, strutils]

const
  InstallMirrorSubpath* = "/.repro/output/install"
    ## The shape a sibling mirror always has under the recipes root:
    ## ``<recipesRoot>/<package><InstallMirrorSubpath>/<rest>``. A path of
    ## this shape carries its own package name, which is what makes it
    ## remappable onto another checkout.

  ImmutableStoreRoots* = ["/nix/store/", "/repro/store/"]
    ## Content-addressed roots. A path under one of these denotes the same
    ## bytes on every host that has it, so it is portable by construction.

  MaxReportedMirrorPaths* = 5
    ## How many DISTINCT offending paths one mirror may name before the rest
    ## are counted instead of printed.

  OriginToken* = "$ORIGIN"
    ## Expanded by the dynamic loader relative to the object being loaded, so
    ## an entry built from it moves with the mirror. Not honoured in
    ## ``PT_INTERP`` — the kernel does no expansion — which is why the
    ## interpreter cannot be made relative and has to be remapped instead.

type
  RuntimePathField* = enum
    rpfInterpreter = "PT_INTERP"
    rpfRunPath = "DT_RUNPATH"

  RelocationVerdict* = enum
    rvPortable        ## Survives the move unchanged.
    rvOwnMirror       ## Inside the mirror being audited; moves with it.
    rvRemappable      ## Names a sibling mirror under a FOREIGN recipes root.
    rvForeign         ## Absolute, outside the store, and not of any shape
                      ## this module knows how to rewrite.

  ElfRuntimeFacts* = object
    isElf*: bool
    parsed*: bool
      ## False for an ELF this reader cannot decode. Reported rather than
      ## skipped: an object that cannot be read has not been checked.
    unsupported*: string
    interpreter*: string
    runPaths*: seq[string]
    needed*: seq[string]

  MirrorPathFinding* = object
    objectPath*: string
    field*: RuntimePathField
    value*: string
    verdict*: RelocationVerdict
    remapped*: string
      ## Where ``value`` lands under the auditing checkout's recipes root.
      ## Empty unless ``verdict`` is ``rvRemappable``.

  MirrorAuditResult* = object
    findings*: seq[MirrorPathFinding]
    unreadable*: seq[string]
      ## ELF objects the reader could not decode, by path.
    elfCount*: int

# ---------------------------------------------------------------------------
# ELF reading
# ---------------------------------------------------------------------------

const
  PtInterp = 3'u32
  PtDynamic = 2'u32
  PtLoad = 1'u32
  DtNull = 0'i64
  DtNeeded = 1'i64
  DtStrTab = 5'i64
  DtStrSz = 10'i64
  DtRpath = 15'i64
  DtRunPath = 29'i64

proc u16(data: string; at: int): uint16 =
  uint16(byte(data[at])) or (uint16(byte(data[at + 1])) shl 8)

proc u32(data: string; at: int): uint32 =
  var value: uint32
  for i in countdown(3, 0):
    value = (value shl 8) or uint32(byte(data[at + i]))
  value

proc u64(data: string; at: int): uint64 =
  var value: uint64
  for i in countdown(7, 0):
    value = (value shl 8) or uint64(byte(data[at + i]))
  value

proc cstringAt(data: string; at: int): string =
  var i = at
  while i < data.len and data[i] != '\0':
    inc i
  data[at ..< i]

proc readElfRuntimeFacts*(path: string): ElfRuntimeFacts =
  ## Read ``PT_INTERP``, ``DT_NEEDED`` and ``DT_RPATH``/``DT_RUNPATH`` from a
  ## little-endian ELF. Anything else — a non-ELF, a big-endian ELF, a
  ## truncated one — is reported through ``isElf``/``parsed``/``unsupported``
  ## rather than returning empty facts that read like a clean object.
  var data: string
  try:
    data = readFile(path)
  except CatchableError:
    return
  if data.len < 20 or not data.startsWith("\x7FELF"):
    return
  result.isElf = true
  let class64 = byte(data[4]) == 2
  if byte(data[4]) notin [1'u8, 2'u8]:
    result.unsupported = "unknown ELF class " & $byte(data[4])
    return
  if byte(data[5]) != 1:
    result.unsupported = "non-little-endian ELF"
    return

  let phoffAt = if class64: 0x20 else: 0x1C
  let phentAt = if class64: 0x36 else: 0x2A
  let phnumAt = if class64: 0x38 else: 0x2C
  if data.len < phnumAt + 2:
    result.unsupported = "truncated ELF header"
    return
  let phoff = int(if class64: u64(data, phoffAt) else: uint64(u32(data, phoffAt)))
  let phentsize = int(u16(data, phentAt))
  let phnum = int(u16(data, phnumAt))
  if phnum == 0:
    result.parsed = true
    return
  if phentsize <= 0 or phoff <= 0 or phoff + phentsize * phnum > data.len:
    result.unsupported = "program header table out of range"
    return

  type Segment = tuple[kind: uint32, offset, filesz, vaddr: int]
  var segments: seq[Segment]
  for i in 0 ..< phnum:
    let at = phoff + i * phentsize
    let kind = u32(data, at)
    var offset, filesz, vaddr: int
    if class64:
      if at + 40 > data.len:
        result.unsupported = "truncated program header"
        return
      offset = int(u64(data, at + 8))
      vaddr = int(u64(data, at + 16))
      filesz = int(u64(data, at + 32))
    else:
      if at + 20 > data.len:
        result.unsupported = "truncated program header"
        return
      offset = int(u32(data, at + 4))
      vaddr = int(u32(data, at + 8))
      filesz = int(u32(data, at + 16))
    segments.add((kind, offset, filesz, vaddr))

  proc fileOffsetOf(vaddr: int): int =
    for seg in segments:
      if seg.kind == PtLoad and vaddr >= seg.vaddr and
          vaddr < seg.vaddr + seg.filesz:
        return seg.offset + (vaddr - seg.vaddr)
    -1

  for seg in segments:
    if seg.kind != PtInterp: continue
    if seg.offset < 0 or seg.offset + seg.filesz > data.len:
      result.unsupported = "PT_INTERP out of range"
      return
    result.interpreter = data[seg.offset ..< seg.offset + seg.filesz]
      .strip(chars = {'\0'})

  for seg in segments:
    if seg.kind != PtDynamic: continue
    if seg.offset < 0 or seg.offset + seg.filesz > data.len:
      result.unsupported = "PT_DYNAMIC out of range"
      return
    let entrySize = if class64: 16 else: 8
    var entries: seq[tuple[tag: int64, val: int]]
    var strTabVaddr = -1
    var strSz = 0
    var at = seg.offset
    while at + entrySize <= seg.offset + seg.filesz:
      var tag: int64
      var val: int
      if class64:
        tag = cast[int64](u64(data, at))
        val = int(u64(data, at + 8))
      else:
        tag = int64(cast[int32](u32(data, at)))
        val = int(u32(data, at + 4))
      at += entrySize
      if tag == DtNull: break
      entries.add((tag, val))
      if tag == DtStrTab: strTabVaddr = val
      elif tag == DtStrSz: strSz = val
    if strTabVaddr < 0:
      result.unsupported = "PT_DYNAMIC without DT_STRTAB"
      return
    let strBase = fileOffsetOf(strTabVaddr)
    if strBase < 0 or strBase >= data.len:
      result.unsupported = "DT_STRTAB outside every PT_LOAD"
      return
    let strLimit = if strSz > 0: min(strBase + strSz, data.len) else: data.len
    for entry in entries:
      if entry.tag notin [DtNeeded, DtRpath, DtRunPath]: continue
      let at = strBase + entry.val
      if at < 0 or at >= strLimit: continue
      let value = cstringAt(data, at)
      if entry.tag == DtNeeded:
        result.needed.add(value)
      else:
        for part in value.split(':'):
          if part.len > 0 and part notin result.runPaths:
            result.runPaths.add(part)
  result.parsed = true

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

proc normalizeSlashes(value: string): string =
  value.replace('\\', '/')

proc withTrailingSlash(value: string): string =
  let v = normalizeSlashes(value)
  if v.len == 0 or v.endsWith("/"): v else: v & "/"

proc isUnder(path, root: string): bool =
  if root.len == 0: return false
  let p = normalizeSlashes(path)
  let r = withTrailingSlash(root)
  p == r[0 ..< r.high] or p.startsWith(r)

proc splitMirrorPath*(value: string):
    tuple[matched: bool, depName, rest: string] =
  ## Split ``<anyRoot>/<dep>/.repro/output/install/<rest>``. The package name
  ## is what travels: it is the only part of a foreign path that still means
  ## something under a different checkout.
  let v = normalizeSlashes(value)
  let marker = InstallMirrorSubpath & "/"
  var idx = v.find(marker)
  var tail = ""
  if idx < 0:
    if v.endsWith(InstallMirrorSubpath):
      idx = v.len - InstallMirrorSubpath.len
    else:
      return
  else:
    tail = v[idx + marker.len .. ^1]
  let head = v[0 ..< idx]
  if head.len == 0: return
  let depName = head.rsplit('/', maxsplit = 1)[^1]
  if depName.len == 0 or depName == "." or depName == "..": return
  (true, depName, tail)

proc installMirrorCheckoutRoots*(mirrorRoot: string):
    tuple[matched: bool, recipesRoot, packageName: string] =
  ## Read a mirror root back into the two names that identify it:
  ## ``<recipesRoot>/<package>/.repro/output/install``. Deriving the recipes
  ## root FROM the mirror rather than from a caller-supplied setting keeps the
  ## audit's notion of "here" identical to the path it is auditing.
  let v = normalizeSlashes(mirrorRoot).strip(leading = false, chars = {'/'})
  if not v.endsWith(InstallMirrorSubpath): return
  let head = v[0 ..< v.len - InstallMirrorSubpath.len]
  if head.len == 0 or '/' notin head: return
  let parts = head.rsplit('/', maxsplit = 1)
  if parts[0].len == 0 or parts[1].len == 0: return
  (true, parts[0], parts[1])

proc remapInstallMirrorPath*(value, recipesRoot: string): string =
  ## Where ``value`` lands under ``recipesRoot``. Empty when ``value`` is not
  ## of the sibling-mirror shape, or when ``recipesRoot`` is empty.
  if recipesRoot.len == 0: return ""
  let split = splitMirrorPath(value)
  if not split.matched: return ""
  result = withTrailingSlash(recipesRoot) & split.depName & InstallMirrorSubpath
  if split.rest.len > 0:
    result.add("/" & split.rest)

proc classifyInstallMirrorPath*(value, recipesRoot, mirrorRoot: string):
    RelocationVerdict =
  ## Pure path arithmetic. ``mirrorRoot`` is the mirror being audited;
  ## ``recipesRoot`` is the checkout doing the auditing.
  if value.len == 0: return rvPortable
  let v = normalizeSlashes(value)
  # SUBSUMED by the relative-path line below — ``$ORIGIN`` never begins with a
  # separator — and kept only because it names the reason. Deleting it changes
  # no answer, so no test can distinguish it; recorded here rather than left
  # for a reader to mistake that for an untested rule.
  if v.startsWith(OriginToken): return rvPortable
  if not v.startsWith("/"): return rvPortable
  for storeRoot in ImmutableStoreRoots:
    if v.startsWith(storeRoot): return rvPortable
  if isUnder(v, mirrorRoot): return rvOwnMirror
  if isUnder(v, recipesRoot): return rvPortable
  let remapped = remapInstallMirrorPath(v, recipesRoot)
  if remapped.len == 0: return rvForeign
  # Also SUBSUMED, by the line above it: a remap that equals its input is by
  # construction rooted at ``recipesRoot``, so ``isUnder`` has already
  # answered. Same status as the ``$ORIGIN`` line — inert, and said so.
  if remapped == v: return rvPortable
  rvRemappable

# ---------------------------------------------------------------------------
# Auditing a whole mirror
# ---------------------------------------------------------------------------

proc classifyInto(findings: var seq[MirrorPathFinding]; objectPath: string;
                  field: RuntimePathField; value, recipesRoot,
                  mirrorRoot: string) =
  let verdict = classifyInstallMirrorPath(value, recipesRoot, mirrorRoot)
  if verdict in {rvPortable, rvOwnMirror}: return
  findings.add(MirrorPathFinding(
    objectPath: objectPath, field: field, value: value, verdict: verdict,
    remapped: if verdict == rvRemappable:
                remapInstallMirrorPath(value, recipesRoot)
              else: ""))

proc auditInstallMirrorRelocatability*(mirrorRoot, recipesRoot: string):
    MirrorAuditResult =
  ## Every ELF under ``mirrorRoot``, every absolute runtime path it records.
  ## Walks the WHOLE tree rather than a list of directory names: the object
  ## that first exposed this was a CPython extension module nested three
  ## levels below ``usr/lib``, and a check that only looks where binaries are
  ## expected is a check that cannot see it.
  if mirrorRoot.len == 0 or not dirExists(mirrorRoot):
    return
  for path in walkDirRec(mirrorRoot, yieldFilter = {pcFile},
                         followFilter = {pcDir}):
    let facts = readElfRuntimeFacts(path)
    if not facts.isElf: continue
    inc result.elfCount
    if not facts.parsed:
      result.unreadable.add(path)
      continue
    classifyInto(result.findings, path, rpfInterpreter, facts.interpreter,
      recipesRoot, mirrorRoot)
    for entry in facts.runPaths:
      classifyInto(result.findings, path, rpfRunPath, entry, recipesRoot,
        mirrorRoot)

proc describeMirrorPathFinding*(packageName: string;
                                finding: MirrorPathFinding): string =
  ## Operator-facing. Exit 127 names neither the package nor the path; this
  ## names both, plus the field, which is what says whether the failure will
  ## be an unrunnable file or a library that goes missing halfway in.
  result = "install mirror: "
  result.add(if packageName.len > 0: packageName else: "<unnamed package>")
  result.add(": ")
  result.add($finding.field)
  result.add(" of ")
  result.add(finding.objectPath)
  result.add(" names ")
  result.add(finding.value)
  case finding.verdict
  of rvRemappable:
    result.add(", which belongs to another checkout of this recipe set; here it is ")
    result.add(finding.remapped)
  of rvForeign:
    result.add(", which is outside every content-addressed store and outside this checkout")
  else:
    discard

# ---------------------------------------------------------------------------
# Repair
# ---------------------------------------------------------------------------

type
  MirrorRelocationOutcome* = object
    ok*: bool
    patchedObjects*: int
    audit*: MirrorAuditResult
    error*: string

  MirrorPatchRunner* = proc (executable: string; args: seq[string]):
    tuple[output: string, exitCode: int] {.closure.}
    ## How this module reaches ``patchelf``. INJECTED rather than resolved
    ## here, for two reasons that point the same way: ambient PATH resolution
    ## is exactly what this repository's execution model forbids a library
    ## from doing, and a caller that supplies the runner is a caller whose
    ## refusal paths — no tool, a tool that fails, a tool that reports
    ## success without writing anything — can be driven by a test instead of
    ## reasoned about.

proc relocateInstallMirror*(mirrorRoot, recipesRoot: string;
                            patchelfExe: string;
                            runPatch: MirrorPatchRunner):
    MirrorRelocationOutcome =
  ## Rewrite every ``rvRemappable`` path in ``mirrorRoot`` onto
  ## ``recipesRoot``.
  ##
  ## Refusal, not best-effort. If ``patchelf`` is not available, or a rewrite
  ## fails, the caller must treat the mirror as unusable — a PARTIALLY
  ## relocated mirror is the worst of the three states, because it runs far
  ## enough to look like it works.
  result.audit = auditInstallMirrorRelocatability(mirrorRoot, recipesRoot)
  var remappable: seq[MirrorPathFinding]
  for finding in result.audit.findings:
    if finding.verdict == rvRemappable:
      remappable.add(finding)
  if remappable.len == 0:
    # Nothing to rewrite. ``ok`` reports the rewrite, not the mirror's
    # health: surviving ``rvForeign`` paths stay in ``audit`` for the
    # caller to name, because this module cannot rebuild a path that
    # belongs to no checkout.
    result.ok = true
    return
  if patchelfExe.len == 0 or runPatch == nil:
    result.error = "patchelf is required to relocate an install mirror and " &
      "was not available"
    return
  # Group by object so each ELF is rewritten once: patchelf writes the whole
  # file back, and a second pass over the same object would read what the
  # first pass wrote.
  var pending: seq[string]
  for finding in remappable:
    if finding.objectPath notin pending:
      pending.add(finding.objectPath)
  for objectPath in pending:
    let facts = readElfRuntimeFacts(objectPath)
    var args: seq[string]
    let newInterpreter = if facts.interpreter.len > 0:
        remapInstallMirrorPath(facts.interpreter, recipesRoot)
      else: ""
    if newInterpreter.len > 0 and newInterpreter != facts.interpreter:
      args.add("--set-interpreter")
      args.add(newInterpreter)
    var newRunPaths: seq[string]
    var runPathChanged = false
    for entry in facts.runPaths:
      let remapped = remapInstallMirrorPath(entry, recipesRoot)
      if remapped.len > 0 and remapped != entry and
          classifyInstallMirrorPath(entry, recipesRoot, mirrorRoot) ==
            rvRemappable:
        newRunPaths.add(remapped)
        runPathChanged = true
      else:
        newRunPaths.add(entry)
    if runPathChanged:
      args.add("--set-rpath")
      args.add(newRunPaths.join(":"))
    if args.len == 0:
      continue
    var mode: set[FilePermission]
    var restoreMode = false
    try:
      mode = getFilePermissions(objectPath)
      if fpUserWrite notin mode:
        setFilePermissions(objectPath, mode + {fpUserWrite})
        restoreMode = true
    except CatchableError:
      discard
    let outcome = try:
        runPatch(patchelfExe, args & @[objectPath])
      except CatchableError as e:
        (output: e.msg, exitCode: 1)
    if restoreMode:
      try: setFilePermissions(objectPath, mode)
      except CatchableError: discard
    if outcome.exitCode != 0:
      result.error = "patchelf failed on " & objectPath & ": " &
        outcome.output.strip()
      return
    inc result.patchedObjects
  # Re-audit rather than assume: the rewrite is the claim, and the only
  # evidence for it is the mirror as it now reads.
  result.audit = auditInstallMirrorRelocatability(mirrorRoot, recipesRoot)
  var stillRemappable = 0
  for finding in result.audit.findings:
    if finding.verdict == rvRemappable: inc stillRemappable
  if stillRemappable > 0:
    result.ok = false
    result.error = "install mirror still carries " & $stillRemappable &
      " foreign-checkout path(s) after relocation"
  else:
    result.ok = true

proc relocateRestoredInstallMirror*(prefix, patchelfExe: string;
                                    runPatch: MirrorPatchRunner):
    tuple[ok: bool, message: string] =
  ## A restored install mirror was built under a DIFFERENT checkout, and its
  ## ELF objects still say so.
  ##
  ## ``PT_INTERP`` is the one that stops everything: the kernel resolves it
  ## before the process exists, so a loader path belonging to the producer's
  ## checkout turns an artifact that is plainly on disk into ``exit 127`` with
  ## no package name and no path in the message. ``DT_RUNPATH`` is the same
  ## defect with a quieter failure — the loader skips a directory that is not
  ## there, the tool starts, and only the code paths that reach the missing
  ## library break.
  ##
  ## Both are repairable here and only here: the path names the PACKAGE it
  ## belongs to, and this checkout has that package under its own recipes
  ## root. Anything that survives the rewrite is NAMED rather than swallowed.
  # Subsumed by the shape check below — the empty string cannot end in the
  # mirror subpath — and kept for the same reason as the two inert lines in
  # ``classifyInstallMirrorPath``: it states an intent no answer depends on.
  if prefix.len == 0: return (true, "")
  let roots = installMirrorCheckoutRoots(prefix)
  if not roots.matched: return (true, "")
  if not dirExists(prefix): return (true, "")
  let outcome = relocateInstallMirror(prefix, roots.recipesRoot,
    patchelfExe, runPatch)
  var lines: seq[string]
  if outcome.patchedObjects > 0:
    lines.add("cache substitute: relocated " & $outcome.patchedObjects &
      " ELF object(s) in \"" & roots.packageName &
      "\" onto this checkout")
  # BOUNDED, and the bound is the point. One mirror can carry hundreds of
  # unrepairable entries that are all the same producer directory seen from
  # a hundred objects; printing every one is a report nobody reads, which is
  # the same end state as printing none. Name the distinct VALUES, up to the
  # bound, and then say how many were withheld — so the count is never the
  # thing that got truncated.
  var reported: seq[string]
  var withheld = 0
  for finding in outcome.audit.findings:
    if finding.verdict == rvRemappable and outcome.ok: continue
    if finding.value in reported: continue
    if reported.len >= MaxReportedMirrorPaths:
      inc withheld
      continue
    reported.add(finding.value)
    lines.add(describeMirrorPathFinding(roots.packageName, finding))
  if withheld > 0:
    lines.add("install mirror: " & roots.packageName & ": and " &
      $withheld & " further distinct path(s) not shown")
  for unreadablePath in outcome.audit.unreadable:
    lines.add("install mirror: " & roots.packageName &
      ": ELF object could not be read, so it has not been checked: " &
      unreadablePath)
  if outcome.error.len > 0:
    lines.add("install mirror: " & roots.packageName & ": " & outcome.error)
  (outcome.ok, lines.join("\n"))
