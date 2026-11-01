## The deploy agent on an add-on host, split across two units (spec §9.1):
##
##   repro system addon agent-fetch   (``repro-agent-fetch.service``)
##       Unprivileged (a dynamic user, no capabilities, egress to the pinned
##       origins only). Polls, decodes, verifies and selects a manifest;
##       compiles its profile when it ships as source; substitutes every
##       build action's outputs from the cache, trusting only the bootstrap
##       anchors; downloads every ``.deb`` an apt closure lock names; and
##       publishes all of it as one staging directory. It never reads the
##       recipient key or the sequence floor and never writes outside its
##       state directory.
##   repro system addon agent-apply   (``repro-agent-apply.service``)
##       Root, with no network. Copies the newest staging directory into
##       its own directory through ``O_NOFOLLOW`` descriptors and from then
##       on reads only that copy. Runs the whole agent tick again over the
##       copied envelope -- signature, anchors, the v3 attestation block,
##       freshness, pause, sequence floor, quarantine -- re-checks the
##       compiled profile, verifies each staged output against the digest
##       the signed manifest pins, moves it into ``/repro/store`` and runs
##       the switch.
##   repro system addon agent-tick --source S...
##       The single-process tick A7 introduced, kept for operators and
##       tests: the same apply, over a manifest it reads itself. It
##       compiles nothing and takes no staged outputs.
##   repro system addon resume
##       Clear the pause an operator's ``repro system rollback`` set
##       (spec §9.3).
##
## Everything the fetch unit produces is untrusted input to the apply
## unit: the fetch unit is the network-facing half, and a compromise of it
## must yield at most what the signed manifest already allows.

import std/[json, os, posix, strutils, times]

import repro_core/host_apply_lock
import repro_infra
import repro_infra/addon_diagnostics
import repro_infra/profile
import repro_profile
import repro_profile_compile/binary_cache_build_actions
import repro_dsl_stdlib/packages/apt_closure
import repro_peer_cache/auth as peerAuth

import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_deploy_agent/profile_stage
import repro_deploy_agent/tick_record
import repro_deploy_agent/tick_status

import ./addon_apply
import ./addon_secrets
import ./agent_checks
import ./agent_record
import ./agent_switch
import ./apt_hook
import ./evidence
import ./fingerprint
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./verified_compile

export agent_checks, verified_compile
import ./preflight
import ./seams
import ./secrets_ops
import ./store_root

type
  AgentConf* = object
    ## ``/etc/repro/agent.conf`` (``generation0.renderAgentConf``).
    target*: string
    sources*: seq[string]
    profileCompiler*: string

  EAgentStaging* = object of CatchableError
    ## The staging area cannot be copied as the apply unit requires.

const
  StagingLatestName* = "latest"
  StagingResultName* = "result"
  StagedManifestName* = "manifest.rdm"
  StagedCanonicalName* = "profile.canonical"
  StagedActionsName* = "actions.json"
  StagedCompilerRevisionName* = "compiler.revision"
    ## The fetch unit's compiler's own revision (untrusted, diagnostic: it
    ## names the cause of a mismatch, the digest decides).
  StagedOutputsDir* = "outputs"
  StagedDebsDir* = "debs"
  StagedNotesName* = "notes"
  ApplyCopyDirName* = "apply"
  MaxStagedBytes* = 8'i64 * 1024 * 1024 * 1024
    ## The largest staging area the apply unit copies; more is refused.
  MaxStagedDepth* = 64
  CompileTimeoutSec* = 1800

# ---------------------------------------------------------------------------
# Configuration.
# ---------------------------------------------------------------------------

proc parseAgentConf*(text: string): AgentConf =
  ## ``key = value`` lines; ``#`` comments (any bytes, UTF-8 included);
  ## ``source`` repeats. A leading UTF-8 byte-order mark is skipped.
  let text = if text.startsWith("\xEF\xBB\xBF"): text[3 .. ^1] else: text
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    let eq = line.find('=')
    if eq <= 0:
      raise newException(ValueError, AgentConfPath & ": not key = value: " & line)
    let (k, v) = (line[0 ..< eq].strip(), line[eq + 1 .. ^1].strip())
    case k
    of "target": result.target = v
    of "source": result.sources.add(v)
    of "profile-compiler": result.profileCompiler = v
    else:
      raise newException(ValueError, AgentConfPath & ": unknown key " & k)
  if result.target.len == 0 or result.sources.len == 0:
    raise newException(ValueError, AgentConfPath &
      " names no target or no source")

proc loadAgentConf*(path = AgentConfPath): AgentConf =
  if not fileExists(path):
    raise newException(ValueError, path & " is absent: this host was " &
      "bootstrapped without a deploy agent (--target, --manifest)")
  parseAgentConf(readFile(path))

proc applyStagingRoot*(): string =
  ## Where the apply unit reads the staging area: the dynamic user's real
  ## state directory, not the ``/var/lib/<name>`` link systemd keeps to it.
  let priv = "/var/lib/private" / AgentFetchStateName / "staging"
  if dirExists(priv): priv else: "/var/lib" / AgentFetchStateName / "staging"

proc fetchStagingRoot*(): string =
  ## The fetch unit's staging area: under its ``StateDirectory=``
  ## (``$STATE_DIRECTORY`` in the unit), else the path the apply unit
  ## reads.
  let sd = getEnv("STATE_DIRECTORY")
  (if sd.len > 0: sd.split(':')[0] else: "/var/lib" / AgentFetchStateName) /
    "staging"

proc applyCopyDir*(): string = AgentDir / ApplyCopyDirName

proc actionsToJson*(actions: seq[ProfileBuildAction]): string = $(%actions)

proc actionsFromJson*(text: string): seq[ProfileBuildAction] =
  to(parseJson(text), seq[ProfileBuildAction])

proc stagedDebName*(url: string): string =
  ## The file a ``.deb`` is staged under: the SHA-256 of its URL, so the
  ## name carries nothing the archive chose.
  sha256Hex(url) & ".deb"

# ---------------------------------------------------------------------------
# The fetch unit.
# ---------------------------------------------------------------------------

type FetchReport* = object
  kind*: string        ## an agent outcome name, or "staged"
  message*: string
  stagingDir*: string

proc writeResult(dir, kind, message, errorCode: string) =
  writeFile(dir / StagingResultName, kind & "\n" & errorCode & "\n" &
    message.replace('\n', ' ') & "\n")

proc publishStaging(root, dir: string): string =
  ## Rename the finished ``dir`` into place and point ``latest`` at it
  ## (written beside and renamed, so a reader sees the old name or the new
  ## one); older staging directories are removed.
  let name = format(getTime(), "yyyyMMdd'T'HHmmss") & "-" &
             $getTime().nanosecond & "-" & $getCurrentProcessId()
  result = root / name
  moveDir(dir, result)
  let tmp = root / (".latest-" & $getCurrentProcessId())
  writeFile(tmp, name & "\n")
  moveFile(tmp, root / StagingLatestName)
  for kind, p in walkDir(root):
    if kind == pcDir and p != result and not extractFilename(p).startsWith("."):
      try: removeDir(p) except CatchableError: discard

proc compileProfile(conf: AgentConf; m: DeployManifest;
                    dir, workspace: string): string =
  ## Run the configured profile compiler over the staged source as this
  ## (unprivileged) process; "" when it produced ``profile.canonical`` and
  ## ``actions.json``, else why not. Refused outright as root: compiling
  ## runs code the profile's macros choose, which the fetch unit's dynamic
  ## user may do and root never does (threat model F2, G25).
  if geteuid() == 0:
    return "refusing to compile a profile as root: only the unprivileged " &
      "fetch unit compiles (spec §9.1)"
  if conf.profileCompiler.len == 0:
    return "the manifest's profile is source and this host has no " &
      "profile-compiler configured in " & AgentConfPath
  # The compile works in its own scratch directory, never in the staging
  # area (only the compiler's two outputs are handed over), and the dynamic
  # user has no home, so the compiler's caches go there too.
  let module = stageProfileSources(workspace / "source", m.profileText,
                                   m.profileFiles)
  for v in ["HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]:
    putEnv(v, workspace / "home")
  createDir(workspace / "home")
  let argv = @[conf.profileCompiler, "deploy-agent", "compile-profile",
    "--staged", module, "--canonical-out", dir / StagedCanonicalName,
    "--actions-out", dir / StagedActionsName,
    "--state-dir", workspace / "state",
    "--revision-out", dir / StagedCompilerRevisionName] & compileFactArgs(m)
  let r = runHostTool(argv, timeoutSec = CompileTimeoutSec)
  if r.exitCode != 0:
    return "the profile compiler failed (exit " & $r.exitCode & "): " &
      r.output.strip()
  if not fileExists(dir / StagedCanonicalName):
    return "the profile compiler wrote no canonical text"
  ""

proc stageOutputs(m: DeployManifest; actions: seq[ProfileBuildAction];
                  dir, scratch: string; notes: var seq[string]) =
  ## Substitute every action's outputs into ``dir/outputs/<n>/`` from the
  ## caches ``caches.conf`` names, each with exactly the publisher keys it
  ## lists (default-untrusted), and each bound to the digest the signed
  ## manifest pins: a trusted publisher's archive with other bytes is a
  ## miss, never staged.
  let pinned = pinActionsToClosureDigests(m, actions)
  if pinned.refusal.len > 0:
    notes.add("closure digests: " & pinned.refusal)
    return
  var cfg = resolveBuildActionCacheConfig()
  when mutated("agent-substitutes-untrusted"):
    # An endpoint list with no trusted keys and trust enforcement off: the
    # apply path before reprobuild 1c2752eef9.
    for e in cfg.endpoints.mitems:
      e.enforceTrust = false
      e.trustedSigners = @[]
  for i, a in pinned.actions:
    var b = a
    b.cwd = dir / StagedOutputsDir / $i
    createDir(b.cwd)
    let r = trySubstituteBuildAction(b, cfg, scratch)
    if not r.hit:
      notes.add("action " & a.id & ": not staged: " & r.reason)

proc stageDebs(canonical: string; dir: string; notes: var seq[string]) =
  ## Download every ``.deb`` an apt closure lock in ``canonical`` names
  ## into ``dir/debs``, verified against the lock (the apply unit verifies
  ## its copy again: these bytes are untrusted to it).
  var prof: SystemProfile
  try: prof = parseSystemProfile(canonical)
  except CatchableError: return
  let fetch = httpDebFetcher()
  for r in prof.resources:
    # A unit's closure and an operator tool's (`linux.addOnTool`): the
    # apply unit realises both from these copies.
    let lockText =
      if r.kind == srkSystemdSystemUnit: r.suAptClosureLock
      elif r.kind == srkLinuxAddOnTool: r.atAptClosureLock
      else: ""
    if lockText.len == 0: continue
    let lock = parseAptClosureLock(lockText)
    for d in lock.debs:
      let url = debUrl(lock, d)
      let dest = dir / StagedDebsDir / stagedDebName(url)
      if fileExists(dest): continue
      createDir(parentDir(dest))
      try:
        fetch(url, dest, d.size)
        if sha256Hex(readFile(dest)) != d.sha256:
          removeFile(dest)
          notes.add(d.name & ": the download does not match the lock")
      except CatchableError as e:
        try: removeFile(dest) except CatchableError: discard
        notes.add(d.name & ": " & e.msg)

proc runAgentFetch*(conf: AgentConf; anchors: TrustAnchors;
                    stagingRoot: string; deps: AgentDeps;
                    fetchTimeoutMs = 30_000): FetchReport =
  ## One fetch: select, stage and publish (see the module header).
  createDir(stagingRoot)
  let dir = stagingRoot / (".build-" & $getCurrentProcessId())
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  let cfg = AgentConfig(target: conf.target, sources: conf.sources,
    anchors: anchors, fetchTimeoutMs: fetchTimeoutMs)
  let sel = selectManifest(cfg, deps)
  # Test seam (seam builds only): the gates observe the fetch unit from
  # inside its control group while it is paused here.
  seamPause(stagingRoot.parentDir, "agent-fetch-after-select")
  if not sel.found:
    writeResult(dir, $sel.outcome.kind, sel.outcome.message,
                sel.outcome.errorCode)
    result = FetchReport(kind: $sel.outcome.kind, message: sel.outcome.message)
    result.stagingDir = publishStaging(stagingRoot, dir)
    return
  var bytes = newString(sel.bytes.len)
  for i, b in sel.bytes: bytes[i] = char(b)
  writeFile(dir / StagedManifestName, bytes)
  let m = sel.manifest
  var notes: seq[string]
  var canonical = m.profileText
  var actions = m.buildActions
  if not isCanonicalProfileText(m.profileText):
    # The compile works under the unit's state directory, so its caches
    # (the compiled profile binary, the nimcache) survive to the next tick
    # and an unchanged profile is not compiled again. systemd mounts a
    # DynamicUser unit's StateDirectory= noexec (measured on Debian 13,
    # systemd 257), and the compile runs the binary it links; the unit
    # therefore names this directory in ExecPaths= (generation0
    # `agentFetchUnit`), and the compile refuses a noexec state directory
    # by name rather than failing on the exec.
    let workspace = stagingRoot.parentDir / AgentCompileDirName
    # The staged sources are rebuilt on every tick (`stageProfileSources`);
    # only the compiler's state persists.
    let why = compileProfile(conf, m, dir, workspace)
    if why.len > 0:
      notes.add("profile: " & why)
      canonical = ""
    else:
      canonical = readFile(dir / StagedCanonicalName)
      if actions.len == 0 and fileExists(dir / StagedActionsName):
        actions = actionsFromJson(readFile(dir / StagedActionsName))
  if actions.len > 0:
    stageOutputs(m, actions, dir, stagingRoot.parentDir / "substitute", notes)
  if canonical.len > 0:
    stageDebs(canonical, dir, notes)
  if notes.len > 0:
    writeFile(dir / StagedNotesName, notes.join("\n") & "\n")
  result = FetchReport(kind: "staged",
    message: "sequence " & $m.sequence & " (" & m.deploymentId & ")" &
      (if notes.len > 0: "; " & notes.join("; ") else: ""))
  result.stagingDir = publishStaging(stagingRoot, dir)

# ---------------------------------------------------------------------------
# The hand-off: copying the staging area by descriptor.
# ---------------------------------------------------------------------------

var
  AtFdCwd {.importc: "AT_FDCWD", header: "<fcntl.h>".}: cint
  ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  OCloExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint
  AtSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint

proc c_openat(dirfd: cint; path: cstring; flags: cint; mode: Mode): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}
proc c_fstatat(dirfd: cint; path: cstring; st: var Stat; flags: cint): cint
  {.importc: "fstatat", header: "<sys/stat.h>".}
proc c_fdopendir(fd: cint): ptr DIR {.importc: "fdopendir", header: "<dirent.h>".}

proc openNoFollow(dirfd: cint; name: string; dir: bool): cint =
  let flags = O_RDONLY or ONoFollow or OCloExec or
              (if dir: ODirectory else: 0)
  result = c_openat(dirfd, name.cstring, flags, 0.Mode)
  if result < 0:
    raise newException(EAgentStaging, "cannot open " & name & " in the " &
      "staging area without following a link: " & osErrorMsg(osLastError()))

proc readAllFd(fd: cint; limit: int64): string =
  var buf = newString(65536)
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      raise newException(EAgentStaging, "read failed: " &
        osErrorMsg(osLastError()))
    if n == 0: break
    result.add(buf[0 ..< n])
    if result.len.int64 > limit:
      raise newException(EAgentStaging, "the staging area exceeds " &
        $MaxStagedBytes & " bytes")

proc copyTreeFd(srcFd: cint; dest: string; depth: int; budget: var int64) =
  if depth > MaxStagedDepth:
    raise newException(EAgentStaging, "the staging area is nested deeper " &
      "than " & $MaxStagedDepth)
  createDir(dest)
  let dupFd = posix.dup(srcFd)
  let d = c_fdopendir(dupFd)
  if d == nil:
    discard posix.close(dupFd)
    raise newException(EAgentStaging, "cannot list a staging directory: " &
      osErrorMsg(osLastError()))
  defer: discard closedir(d)
  while true:
    let ent = readdir(d)
    if ent == nil: break
    let name = $cast[cstring](addr ent.d_name)
    if name == "." or name == "..": continue
    var st: Stat
    if c_fstatat(srcFd, name.cstring, st, AtSymlinkNoFollow) != 0:
      raise newException(EAgentStaging, "cannot stat " & name & ": " &
        osErrorMsg(osLastError()))
    if S_ISDIR(st.st_mode):
      let sub = openNoFollow(srcFd, name, dir = true)
      try: copyTreeFd(sub, dest / name, depth + 1, budget)
      finally: discard posix.close(sub)
      # Its own permission bits, after its entries are written (the owner
      # keeps write access to a directory while it is being filled).
      if chmod((dest / name).cstring, Mode(st.st_mode.int and 0o777)) != 0:
        raise newException(EAgentStaging, "cannot set the mode of the copy " &
          "of " & name & ": " & osErrorMsg(osLastError()))
    elif S_ISREG(st.st_mode):
      let fd = openNoFollow(srcFd, name, dir = false)
      try:
        var st2: Stat
        if fstat(fd, st2) != 0 or not S_ISREG(st2.st_mode):
          raise newException(EAgentStaging, name & " is not a regular file")
        let data = readAllFd(fd, budget)
        budget -= data.len.int64
        # The permission bits are kept (never set-id or sticky): a staged
        # output's archive digest covers them, and the copy must hash to
        # the same pin the fetch unit's bytes were checked against.
        writeFileAtomic(dest / name, data, st2.st_mode.int and 0o777)
      finally: discard posix.close(fd)
    else:
      # A symbolic link, a device, a FIFO: nothing the fetch unit has a
      # reason to stage, and each a way to make the apply read elsewhere.
      raise newException(EAgentStaging, "the staging area holds " & name &
        ", which is neither a directory nor a regular file; refused")

proc copyLatestStaging*(stagingRoot, dest: string): string =
  ## Copy the newest complete staging directory into ``dest`` (emptied
  ## first, ``0700``), opening every component relative to its parent's
  ## descriptor with ``O_NOFOLLOW``; return its name. Afterwards nothing
  ## reads the staging area again (threat model T38, G33).
  if dirExists(dest): removeDir(dest)
  createDir(parentDir(dest))
  createDir(dest)
  setFilePermissions(dest, {fpUserRead, fpUserWrite, fpUserExec})
  let rootFd = c_openat(AtFdCwd, stagingRoot.cstring,
    O_RDONLY or ONoFollow or ODirectory or OCloExec, 0.Mode)
  if rootFd < 0:
    raise newException(EAgentStaging, "cannot open the staging area " &
      stagingRoot & ": " & osErrorMsg(osLastError()))
  defer: discard posix.close(rootFd)
  let lfd = openNoFollow(rootFd, StagingLatestName, dir = false)
  var name = ""
  try: name = readAllFd(lfd, 4096).strip()
  finally: discard posix.close(lfd)
  if name.len == 0 or '/' in name or name.startsWith("."):
    raise newException(EAgentStaging, "the staging area's latest pointer " &
      "is malformed: '" & name & "'")
  let dfd = openNoFollow(rootFd, name, dir = true)
  defer: discard posix.close(dfd)
  var budget = MaxStagedBytes
  copyTreeFd(dfd, dest, 0, budget)
  name

# ---------------------------------------------------------------------------
# The apply.
# ---------------------------------------------------------------------------

proc stagedAptFetcher(copyDir: string): AptDebFetcher =
  ## The apply unit's ``.deb`` source: its own copy of what the fetch unit
  ## staged, never the network. A member that was not staged fails the
  ## apply; the realiser verifies every member against the lock.
  result = proc (url: string; dest: string; expectedSize: int64) =
    let src = copyDir / StagedDebsDir / stagedDebName(url)
    if not fileExists(src):
      raise newException(IOError, url & " was not staged by the fetch " &
        "unit, and the apply unit has no network")
    if getFileSize(src) > expectedSize:
      raise newException(IOError, url & ": the staged file is larger than " &
        "the lock's size")
    copyFile(src, dest)

proc stagedCwdRefusal*(cwd, storeRoot: string): string =
  ## Why an action may not materialise its outputs under ``cwd``, or "".
  ## A compiled action's ``cwd`` is the fetch unit's word, so it is held to
  ## the one shape a store prefix has (spec §8.3): ``<store>/prefixes/
  ## <name>/<version>``, spelled canonically (no empty, ``.`` or ``..``
  ## segment, no trailing ``/``), with no symbolic link on any existing
  ## component below the store root. A string-prefix test alone let
  ## ``<store>/../../etc/cron.d`` through.
  when mutated("agent-install-trusts-cwd"):
    if cwd.startsWith(storeRoot & "/"): return ""
  let base = storeRoot & "/prefixes/"
  if not cwd.startsWith(base):
    return cwd & " is not under " & base
  let rest = cwd[base.len .. ^1]
  let segs = rest.split('/')
  if segs.len != 2:
    return cwd & " is not " & base & "<name>/<version>"
  for seg in segs:
    if seg.len == 0 or seg == "." or seg == ".." or '\0' in seg:
      return cwd & " is not a canonical store path"
  var cur = storeRoot
  for seg in @["prefixes"] & segs:
    cur = cur / seg
    if symlinkExists(cur):
      return cwd & ": " & cur & " is a symbolic link"
  ""

proc installStagedOutputs*(m: DeployManifest; actions: seq[ProfileBuildAction];
                           copyDir: string; storeRoot = StoreRoot) =
  ## Verify each action's staged outputs against the digest the signed
  ## manifest pins, BEFORE anything is moved into the store, linked or
  ## named in a unit; then copy exactly those declared outputs -- nothing
  ## else the staging directory holds -- under the action's ``cwd`` in the
  ## store, through the private writable view. Raises on the first
  ## refusal, mismatch or missing output; nothing is written before every
  ## action has passed.
  let pinned = pinActionsToClosureDigests(m, actions)
  if pinned.refusal.len > 0:
    raise newException(AddonApplyError, "closure digests: " & pinned.refusal)
  for i, a in pinned.actions:
    let bad = stagedCwdRefusal(a.cwd, storeRoot)
    if bad.len > 0:
      raise newException(AddonApplyError, "build action " & a.id &
        " may not materialise there: " & bad & "; nothing was written")
    var staged = a
    staged.cwd = copyDir / StagedOutputsDir / $i
    let refusal = closureDigestRefusal(m, a.id, localOutputsDigest(staged))
    if refusal.len > 0:
      raise newException(AddonApplyError, refusal & "; nothing of it was " &
        "moved into the store")
    # A prefix path already holding other bytes is another closure's: it
    # is never overwritten in place (a new version is a new path).
    for rel in outputRelPaths(a):
      let dst = a.cwd / rel
      if (fileExists(dst) or dirExists(dst) or symlinkExists(dst)) and
          localOutputsDigest(a) != a.expectedOutputDigest:
        raise newException(AddonApplyError, a.cwd & " already holds outputs " &
          "that do not hash to " & a.id & "'s pin; refusing to overwrite them")
  for i, a in pinned.actions:
    # Present already, with the pinned bytes: nothing to do.
    if localOutputsDigest(a) == a.expectedOutputDigest: continue
    if storeRoot == StoreRoot: enterWritableStoreView()
    createDir(a.cwd)
    let src = copyDir / StagedOutputsDir / $i
    when mutated("agent-install-copies-undeclared"):
      var rels: seq[string]
      for kind, p in walkDir(src, relative = true): rels.add(p)
    else:
      let rels = outputRelPaths(a)
    for rel in rels:
      let p = src / rel
      let dst = a.cwd / rel
      createDir(parentDir(dst))
      if dirExists(p): copyDirWithPermissions(p, dst)
      elif fileExists(p): copyFileWithPermissions(p, dst)
    if localOutputsDigest(a) != a.expectedOutputDigest:
      raise newException(AddonApplyError, "the outputs of " & a.id &
        " do not hash to their pin after the copy into the store")

type AgentApplyContext* = object
  ## What one agent apply works from: the copy of the staging area (""
  ## for ``agent-tick``, which has none), and what it reports beside the
  ## outcome.
  copyDir*: string
  drift*: seq[string]

proc agentApplyHook*(ctx: ptr AgentApplyContext; layout: SecretsLayout): ApplyHook =
  ## The apply of one selected, verified manifest on an add-on host.
  result = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    {.cast(gcsafe).}:
      let copyDir = ctx.copyDir
      seamPause(DefaultStateDir, "agent-apply-after-verify")
      # The profile: the signed text when it is canonical; otherwise what
      # the fetch unit compiled, which is untrusted.
      var text = m.profileText
      var actions = m.buildActions
      when mutated("agent-rereads-staging"):
        # Falsifying build: the profile is taken from the staging area
        # again after the copy was verified.
        let staged = applyStagingRoot() / readFile(applyStagingRoot() /
          StagingLatestName).strip() / StagedManifestName
        if fileExists(staged):
          var raw = readFile(staged)
          text = decodeManifest(cast[seq[byte]](raw)).profileText
      let canonical = isCanonicalProfileText(text)
      if not canonical:
        when mutated("agent-compiles-in-apply"):
          # Falsifying build: the reused single-process hook's resolver,
          # i.e. the profile compiled by this root process.
          let conf = loadAgentConf()
          let d = applyCopyDir() / "compile"
          createDir(d)
          let module = stageProfileSources(d / "source", m.profileText,
                                           m.profileFiles)
          let r = runHostTool(@[conf.profileCompiler, "deploy-agent",
            "compile-profile", "--staged", module, "--canonical-out",
            d / StagedCanonicalName, "--actions-out", d / StagedActionsName] &
            compileFactArgs(m), timeoutSec = CompileTimeoutSec)
          if r.exitCode != 0:
            return (false, "profile compile failed: " & r.output)
          text = readFile(d / StagedCanonicalName)
        else:
          if copyDir.len == 0 or not fileExists(copyDir / StagedCanonicalName):
            var why = "the manifest's profile is source, and no compiled " &
              "text was staged for it"
            if copyDir.len > 0 and fileExists(copyDir / StagedNotesName):
              why.add(" (fetch unit: " &
                readFile(copyDir / StagedNotesName).strip() & ")")
            return (false, why)
          text = readFile(copyDir / StagedCanonicalName)
          let actionsJson = if fileExists(copyDir / StagedActionsName):
                              readFile(copyDir / StagedActionsName) else: ""
          # The fetch unit's compile is a cache of the producer's: what it
          # emitted is applied only when it hashes to the signed pin (B1).
          let revision = if fileExists(copyDir / StagedCompilerRevisionName):
                           readFile(copyDir / StagedCompilerRevisionName).strip()
                         else: ""
          let pin = compiledProfileCheck(m, text, actionsJson, revision)
          if pin.len > 0:
            recordCompiledProfileRefusal(m, pin)
            return (false, pin)
          if actions.len == 0 and actionsJson.len > 0:
            actions = actionsFromJson(actionsJson)
      var prof: SystemProfile
      try: prof = parseSystemProfile(text)
      except CatchableError as e:
        return (false, "the profile does not parse: " & e.msg)
      let refusal = agentProfileRefusal(m, prof, not canonical,
                                        DefaultStateDir)
      if refusal.len > 0:
        return (false, refusal)
      if actions.len > 0:
        if copyDir.len == 0:
          return (false, "the manifest carries build actions, which only " &
            "the fetch unit substitutes; agent-tick takes none")
        try:
          installStagedOutputs(m, actions, copyDir)
        except CatchableError as e:
          return (false, e.msg)
      var failedAtFloor: seq[string]
      let r = tickApply(DefaultStateDir, layout, m, proc(o: AddonApplyOptions):
          AddonApplyResult =
        var o2 = o
        o2.userProfileText = text
        o2.agentSequence = m.sequence
        o2.agentRecord = agentRecordOf(m)
        o2.rollbackFloor = m.rollbackFloor
        if copyDir.len > 0: o2.aptFetch = stagedAptFetcher(copyDir)
        try:
          result = runAddonApply(o2)
        except AddonRolledBack as e:
          raise newException(EApplyRolledBack, e.msg)
        except AddonFailedAtFloor as e:
          # Not committed, not reverted: the floor kept the switch in place.
          raise newException(EApplyFailedAtFloor, e.msg)
        failedAtFloor = result.failedAtFloor
        for d in result.drift: ctx.drift.add("apply drift " & d))
      if r.ok and failedAtFloor.len > 0:
        raise newException(EApplyFailedAtFloor, failedAtFloor.join("; "))
      r

proc recordStale(o: AgentOutcome) =
  ## ``aoStale`` leaves an evidence record (spec §9.2, threat model G32).
  if o.kind == aoStale:
    try:
      discard writeEvidenceRecord("stale-manifest", %*{
        "target": o.target, "sequence": o.sequence,
        "deploymentId": o.deploymentId, "message": o.message})
    except CatchableError as e:
      stderr.write("repro-addon: cannot write the stale-manifest evidence " &
        "record: " & e.msg & "\n")

proc runAddonAgentTick*(cfg: AgentConfig; ctx: var AgentApplyContext;
                        what: string): RecordedTick =
  ## One tick on an add-on host: the agent's checks (v3 required), the
  ## sealed section through the add-on, the apply above.
  var cfg = cfg
  cfg.requireAttestations = true
  let layout = defaultSecretsLayout()
  cfg.secretsSink = proc(m: DeployManifest): string {.gcsafe.} =
    {.cast(gcsafe).}:
      acceptSealedSection(DefaultStateDir, layout, m)
  var deps: AgentDeps
  deps.apply = agentApplyHook(addr ctx, layout)
  let ctxp = addr ctx
  deps.driftProbe = proc(): seq[string] {.gcsafe.} =
    {.cast(gcsafe).}:
      result = hookEventsSince(AgentStateDir / AptHookCursorName)
      result.add(ctxp.drift)
  var hostLock = acquireHostApplyLock(what)
  defer: hostLock.release()
  retryPendingSecretsCommit(DefaultStateDir, layout)
  # An operator rollback pauses this agent (spec §9.3): it is registered
  # with the add-on, whose rollback writes the agent's pause marker.
  registerAgentState(DefaultStateDir, cfg.stateDir)
  # A host whose agent applied outside the switch before (its generations
  # in the agent's own state directory) is taken over first (§9
  # "Migration"): one switch that adopts what that agent applied.
  if needsLegacyMigration(DefaultStateDir, cfg.stateDir):
    let legacyGen = legacyAgentGeneration(cfg.stateDir)
    try:
      let r = migrateLegacyAgentState(DefaultStateDir, cfg.stateDir,
                                      cfg.target, readHostname())
      stdout.write("migration: add-on generation " & r.generationId &
        " took over agent generation " & legacyGen & "\n")
    except CatchableError as e:
      return RecordedTick(exitCode: deployAgentExitCode(aoApplyFailed),
        outcome: AgentOutcome(kind: aoApplyFailed, target: cfg.target,
          errorCode: "addon_migration_failed",
          message: "migrating agent generation " & legacyGen & " into " &
            "the add-on switch failed; nothing was applied: " & e.msg))
  result = runAgentTickRecorded(cfg, deps)
  if not result.raised: recordStale(result.outcome)
  recordAgentDrift((if result.raised: "tickRaised" else: $result.outcome.kind),
                   (if result.raised: 0'u64 else: result.outcome.sequence),
                   result.addOnDrift)

proc printTick(t: RecordedTick) =
  if t.raised:
    stdout.write("outcome: tickRaised\nmessage: " & t.error & "\n")
  else:
    stdout.write("outcome: " & $t.outcome.kind & "\n" &
                 "sequence: " & $t.outcome.sequence & "\n" &
                 "message: " & t.outcome.message & "\n")
  for d in t.addOnDrift: stdout.write("add-on drift: " & d & "\n")

# ---------------------------------------------------------------------------
# The verbs.
# ---------------------------------------------------------------------------

proc takeArg(args: seq[string]; i: var int; flag: string): string =
  let a = args[i]
  if a.startsWith(flag & "="): return a[flag.len + 1 .. ^1]
  if i + 1 >= args.len: raise newException(ValueError, flag & " needs a value")
  inc i
  args[i]

proc runAgentFetchCli*(args: seq[string]): int =
  ## ``repro system addon agent-fetch``: exit 0 when a staging directory
  ## was published (whatever it says), 1 when it could not be.
  if args.len != 0:
    stderr.write("usage: repro system addon agent-fetch\n")
    return 2
  try:
    let conf = loadAgentConf()
    let r = runAgentFetch(conf, peerAuth.loadTrustAnchors(DeploySignersPath),
                          fetchStagingRoot(), AgentDeps())
    stdout.write("fetch: " & r.kind & ": " & r.message & "\nstaged: " &
                 r.stagingDir & "\n")
    0
  except CatchableError as e:
    stderr.write("repro system addon agent-fetch: " & e.msg & "\n")
    1

proc stagedResult(copyDir: string; target: string): AgentOutcome =
  ## The fetch unit's own outcome when it selected nothing (reported as
  ## the fetch unit's word: it changes nothing on the host).
  let lines = readFile(copyDir / StagingResultName).splitLines()
  var kind = aoSourceError
  for k in AgentOutcomeKind:
    if lines.len > 0 and $k == lines[0].strip(): kind = k
  if kind notin {aoWaiting, aoSourceError, aoRejected, aoAmbiguous}:
    kind = aoSourceError
  AgentOutcome(kind: kind, target: target,
    errorCode: (if lines.len > 1: lines[1].strip() else: ""),
    message: "fetch unit: " & (if lines.len > 2: lines[2].strip() else: ""))

proc runAgentApplyCli*(args: seq[string]): int =
  ## ``repro system addon agent-apply``: one apply from the newest staging
  ## directory; exits with the agent's outcome code.
  if args.len != 0:
    stderr.write("usage: repro system addon agent-apply\n")
    return 2
  var conf: AgentConf
  try: conf = loadAgentConf()
  except CatchableError as e:
    stderr.write("repro system addon agent-apply: " & e.msg & "\n")
    return 2
  var ctx = AgentApplyContext(copyDir: applyCopyDir() / "current")
  try:
    discard copyLatestStaging(applyStagingRoot(), ctx.copyDir)
  except CatchableError as e:
    stderr.write("repro system addon agent-apply: " & e.msg & "\n")
    return 1
  # Falsifying build: the sequence floor kept in the fetch unit's state
  # directory, where its dynamic user can rewrite it.
  let floorDir = when mutated("agent-floor-in-fetch-state"):
                   applyStagingRoot().parentDir / "floor"
                 else: ""
  if not fileExists(ctx.copyDir / StagedManifestName):
    let o = stagedResult(ctx.copyDir, conf.target)
    let t = RecordedTick(outcome: o, exitCode: deployAgentExitCode(o.kind))
    recordTick(AgentStateDir, conf.target, tickStatusFor(o))
    printTick(t)
    return t.exitCode
  let cfg = AgentConfig(target: conf.target,
    sources: @[ctx.copyDir / StagedManifestName],
    anchors: peerAuth.loadTrustAnchors(DeploySignersPath),
    stateDir: AgentStateDir, floorDir: floorDir)
  let t = runAddonAgentTick(cfg, ctx, "repro system addon agent-apply")
  when mutated("agent-floor-in-fetch-state"):
    # The floor belongs to the fetch unit there, as anything in its state
    # directory does.
    for p in walkDirRec(floorDir, yieldFilter = {pcFile, pcDir}):
      setFilePermissions(p, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead, fpOthersWrite,
        fpOthersExec})
    setFilePermissions(floorDir, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead, fpOthersWrite,
      fpOthersExec})
  printTick(t)
  t.exitCode

proc runAgentTickCli*(args: seq[string]): int =
  ## ``repro system addon agent-tick --source S... [--target T]
  ## [--allowed-signers F]``: the single-process tick (see the header).
  var sources: seq[string]
  var target = ""
  var signers = DeploySignersPath
  var i = 0
  try:
    while i < args.len:
      let a = args[i]
      if a == "--source" or a.startsWith("--source="):
        sources.add(takeArg(args, i, "--source"))
      elif a == "--target" or a.startsWith("--target="):
        target = takeArg(args, i, "--target")
      elif a == "--allowed-signers" or a.startsWith("--allowed-signers="):
        signers = takeArg(args, i, "--allowed-signers")
      else:
        raise newException(ValueError, "unknown option " & a)
      inc i
    if sources.len == 0:
      raise newException(ValueError, "at least one --source is required")
  except ValueError as e:
    stderr.write("repro system addon agent-tick: " & e.msg & "\n")
    return 2
  if target.len == 0: target = readHostname()
  let cfg = AgentConfig(target: target, sources: sources,
    anchors: peerAuth.loadTrustAnchors(signers), stateDir: AgentStateDir,
    fetchTimeoutMs: 30_000)
  var ctx: AgentApplyContext
  let t = runAddonAgentTick(cfg, ctx, "repro system addon agent-tick")
  printTick(t)
  t.exitCode

proc runResumeCli*(args: seq[string]): int =
  ## ``repro system addon resume``: clear the pause marker (spec §9.3).
  if args.len != 0:
    stderr.write("usage: repro system addon resume\n")
    return 2
  # The configured agent's marker, and every agent the add-on's rollback
  # pauses (registered with it, or at a well-known state directory).
  var resumed = resumeAgents(DefaultStateDir)
  if clearPauseMarker(AgentStateDir) and AgentStateDir notin resumed:
    resumed.add(AgentStateDir)
  if resumed.len > 0:
    stdout.write("the deploy agent of " & resumed.join(", ") & " is no " &
      "longer paused; the next tick converges to the latest manifest\n")
  else:
    stdout.write("the deploy agent was not paused\n")
  0

proc pauseAfterRollback*(generation: string) =
  ## An operator rollback on a host whose deploy agent is configured
  ## pauses it (spec §9.3), naming the generation and the operator.
  if not fileExists(AgentConfPath): return
  let op = getEnv("SUDO_USER", getEnv("USER", getEnv("LOGNAME", "root")))
  writePauseMarker(AgentStateDir, generation, op)
