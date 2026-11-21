## `ReprobuildBackend`: the operations the agent host delegates, performed
## with Reprobuild (ReproOS-Agent-Harbor-Integration M3 deliverable 3, M4's
## restart preview).
##
## - ownership: an installed path (or the active application's executable)
##   resolves through `ownership.resolveOwnership`;
## - checkout: `checkout.createCheckout` into the workspace the host made;
## - build and test: the `repro` binary, run in the workspace's package
##   directory with a PREVIEW store, so a build of the change publishes its
##   output beside, never over, the installed prefix;
## - preview (supervised restart): run the change's built executable from
##   the preview store with its own HOME and XDG directories, so the
##   preview neither reads nor writes the user's active state.
##
## Every child runs without a shell, with a bounded wall time, and with
## its output captured.

import std/[algorithm, os, osproc, posix, sets, strtabs, strutils, tables, times]

import repro_core/ambient_execution
import repro_agent_protocol
import repro_project_dsl/install_mirror_resolver

import repro_remix
import repro_peer_cache/auth as peerAuth

import ./[ownership, checkout, preview_strategy, stage]

type
  ReprobuildBackend* = ref object of Backend
    reproExe*: string
      ## The `repro` binary of the active generation.
    storeRoot*: string
      ## The installed store, read only.
    catalogRoots*: seq[string]
      ## Recipes roots of the active generation.
    previewStoreRoot*: string
      ## Where builds of changes publish.
    activeAppPath*: string
      ## The focused application's executable, as the consent surface
      ## captured it at invocation (`context.active-app`).
    timeoutSeconds*: int
    checkouts*: Table[string, Checkout] ## by workspace root
    extraEnv*: seq[(string, string)]
      ## Added to every child environment (tool PATH, provisioning mode).
    driver*: GenerationDriver
      ## The generation system changes are activated in (M5).
    overlayRoot*: string
      ## Where staged overlays (signed draft Remix manifests and their
      ## patch blobs) are kept, private to this machine.
    remixKey*: PeerKeypair
      ## The local author key staged overlays are signed with.
    staged*: Table[string, StagedChange] ## by hex release id
    blocked*: HashSet[string]
      ## Hex release ids under a blocking verdict or revocation (Remix
      ## Invariant I-7), as trust policy reports them.
    compositionParents*: Table[string, seq[string]]
      ## Workspace root -> the releases a composed workspace was built from.
    hcr*: HcrAdvertisement
      ## What the focused application's HCR agent advertised, if one
      ## connected; decides between HCR and restart (`preview_strategy`).

proc newReprobuildBackend*(reproExe, storeRoot: string;
                           catalogRoots: seq[string];
                           previewStoreRoot: string;
                           timeoutSeconds = 1800): ReprobuildBackend =
  ReprobuildBackend(reproExe: reproExe, storeRoot: storeRoot,
                    catalogRoots: catalogRoots,
                    previewStoreRoot: previewStoreRoot,
                    timeoutSeconds: timeoutSeconds)

proc failed(detail: string): OpResult =
  OpResult(status: osFailed, detail: detail)

proc tail(s: string; n = 8192): string =
  if s.len <= n: s else: s[^n .. ^1]

proc run(b: ReprobuildBackend; exe: string; args: seq[string]; cwd: string;
         env: StringTableRef): tuple[code: int; output: string] =
  ## Run `exe` with `args`, capturing stdout and stderr together, killing it
  ## after `timeoutSeconds`. Output is drained as it arrives (`hasData` is a
  ## `select` on the pipe, and `posix.read` returns what is there), so a
  ## chatty child cannot fill the pipe and a silent one cannot outlive its
  ## deadline. It waits at the host's cancellation checkpoint, so a
  ## cancelled operation's child is terminated (then killed, after a grace
  ## period) and `OperationCancelled` raised; what it printed is
  ## discarded with it. Ambient by necessity for now (see `checkout.git`):
  ## the executables are the active generation's.
  let p = uncontrolledStartProcess(exe, workingDir = cwd, args = args,
                                   env = env, options = {poStdErrToStdOut})
  defer: p.close()
  var output = ""
  var buf: array[4096, char]
  let fd = cint(p.outputHandle)
  let deadline = epochTime() + float(b.timeoutSeconds)
  template stopCancelled() =
    p.terminate()
    let grace = epochTime() + 5
    while p.running and epochTime() < grace:
      sleep(10)
    if p.running:
      p.kill()
    discard p.waitForExit()
    b.raiseCancelled()
  while true:
    if p.hasData:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n > 0:
        output.add buf.toOpenArray(0, n - 1).join("")
        if b.checkpoint(0):
          stopCancelled()
        continue
      if n == 0:
        break # EOF: the child closed its output
    elif not p.running:
      # Exited; drain whatever is still buffered.
      while p.hasData:
        let n = posix.read(fd, addr buf[0], buf.len)
        if n <= 0: break
        output.add buf.toOpenArray(0, n - 1).join("")
      break
    if epochTime() > deadline:
      p.kill()
      discard p.waitForExit()
      return (124, output & "\n[killed after " & $b.timeoutSeconds & "s]\n")
    if b.checkpoint():
      stopCancelled()
  (p.waitForExit(), output)

proc childEnv(b: ReprobuildBackend; overrides: openArray[(string, string)]):
    StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  for (k, v) in b.extraEnv:
    result[k] = v
  for (k, v) in overrides:
    result[k] = v

proc checkoutOf(b: ReprobuildBackend; ws: Workspace): Checkout =
  if not b.checkouts.hasKey(ws.root):
    raise newException(KeyError, "workspace " & ws.id & " has no checkout")
  b.checkouts[ws.root]

proc renderOwnershipDetail(r: OwnershipRecord): string =
  for (k, v) in [("package", r.package), ("version", r.version),
                 ("adapter", r.adapter), ("prefix", r.prefixId),
                 ("prefix-path", r.prefixPath), ("receipt", r.receiptDigest),
                 ("recipe", r.recipeName), ("recipe-dir", r.recipeDir),
                 ("recipe-tree", r.recipeTreeDigest)]:
    result.add k & "=" & v & "\n"
  for g in r.homeGenerations:
    result.add "home-generation=" & g & "\n"
  for p in r.pending:
    result.add "pending=" & p & "\n"

proc ownershipFor(b: ReprobuildBackend; target: string): OwnershipRecord =
  ## `active-app` resolves the focused application's executable; a package
  ## name resolves that package's recipe output in the catalog.
  if target == ActiveAppTarget:
    if b.activeAppPath.len == 0:
      raise newException(OwnershipError, "no active application was captured")
    return resolveOwnership(b.storeRoot, b.catalogRoots, b.activeAppPath)
  for root in b.catalogRoots:
    let info = readRealizationInfoFile(root, target)
    if info.storeRelativePath.len > 0:
      return resolveOwnership(b.storeRoot, b.catalogRoots,
                              b.storeRoot / info.storeRelativePath)
  raise newException(OwnershipError, "no-recipe: no installed output of " &
    target & " in the catalog roots")

method resolveOwnership*(b: ReprobuildBackend; target: string): OpResult =
  try:
    OpResult(status: osCompleted, output: renderOwnershipDetail(
      b.ownershipFor(target)))
  except OwnershipError as e:
    failed(e.msg)

method createCheckout*(b: ReprobuildBackend; package, root: string): OpResult =
  ## `package` is the recipe name the provider resolved ownership of.
  try:
    let rec = b.ownershipFor(package)
    let co = createCheckout(rec, root, storeRoot = b.storeRoot)
    b.checkouts[root] = co
    OpResult(status: osCompleted, output: "base=" & co.baseCommit & "\n" &
      renderOwnershipDetail(rec))
  except OwnershipError as e:
    failed(e.msg)
  except CheckoutError as e:
    failed(e.msg)

method diff*(b: ReprobuildBackend; ws: Workspace): OpResult =
  try:
    OpResult(status: osCompleted, output: diffAgainstBase(b.checkoutOf(ws).root))
  except CheckoutError, KeyError:
    failed(getCurrentExceptionMsg())

proc previewOutput(co: Checkout): string =
  ## The preview store path the latest build of the change published, from
  ## the sidecar the install mirror wrote beside the workspace's recipe.
  readRealizationInfoFile(co.root, co.ownership.recipeName).storeRelativePath

proc reproIn(b: ReprobuildBackend; co: Checkout; args: seq[string]): OpResult =
  let env = b.childEnv([("REPRO_STORE_ROOT", b.previewStoreRoot),
                        ("REPRO_INSTALL_MIRROR_MODE", "hashed")])
  let (code, output) = b.run(b.reproExe, args, co.packageDir, env)
  if code != 0:
    return OpResult(status: osFailed, detail: "repro " & args.join(" ") &
      " exited " & $code, output: output.tail)
  OpResult(status: osCompleted, detail: co.previewOutput, output: output.tail)

method runBuild*(b: ReprobuildBackend; ws: Workspace; op: Operation): OpResult =
  ## `repro build [target]` in the workspace. `detail` is the preview
  ## store path of the change's output.
  try:
    let co = b.checkoutOf(ws)
    var args = @["build"]
    if op.arg("target").len > 0:
      args.add op.arg("target")
    b.reproIn(co, args)
  except KeyError:
    failed(getCurrentExceptionMsg())

method runTest*(b: ReprobuildBackend; ws: Workspace; op: Operation): OpResult =
  ## `repro build <target>` for a named test edge (default `test`).
  try:
    let co = b.checkoutOf(ws)
    let target = if op.arg("target").len > 0: op.arg("target") else: "test"
    b.reproIn(co, @["build", target])
  except KeyError:
    failed(getCurrentExceptionMsg())

method preview*(b: ReprobuildBackend; ws: Workspace; op: Operation): OpResult =
  ## Preview the change. The strategy is decided first
  ## (`choosePreviewStrategy`) and reported in `detail` with its reason.
  ##
  ## Restart preview: run `executable` (prefix-relative, e.g. `bin/hello`)
  ## from the change's preview output with its own HOME and XDG directories
  ## under the workspace, so it neither reads nor writes the user's state.
  ## With `baseline=1` the same run uses the INSTALLED prefix instead: the
  ## "before" the user compares against. `preview.stop` has nothing to stop
  ## for a run-to-completion preview and succeeds.
  ##
  ## An HCR decision is reported and refused: driving `repro hcr
  ## coordinate` against the running application is not wired yet.
  if op.kind == okPreviewStop:
    return OpResult(status: osCompleted)
  try:
    let co = b.checkoutOf(ws)
    let baseline = op.arg("baseline") == "1"
    let decision =
      if baseline: PreviewDecision(strategy: psRestart,
                                   reason: "baseline of the installed package")
      else: choosePreviewStrategy(hostDirectProfile(), b.hcr,
                                  changedPathsOf(diffAgainstBase(co.root)))
    let head = "strategy=" & $decision.strategy & " reason=" &
               decision.reason.escape & " "
    if decision.strategy == psHcr:
      return failed(head & "hcr preview is not wired to the coordinator yet")
    let prefix =
      if baseline: co.ownership.prefixPath
      else:
        let rel = co.previewOutput
        if rel.len == 0:
          return failed(head & "the change has not been built")
        b.previewStoreRoot / rel
    let exeRel = op.arg("executable")
    if not isCanonicalRelPath(exeRel):
      return failed("path-escape: executable " & exeRel.escape)
    let exe = resolveBeneath(expandFilename(prefix), exeRel)
    let home = co.root / ".reproos-agent" / "preview-home"
    removeDir(home)
    for d in ["", "config", "data", "state", "cache", "run"]:
      createDir(home / d)
    let env = b.childEnv([("HOME", home),
      ("XDG_CONFIG_HOME", home / "config"), ("XDG_DATA_HOME", home / "data"),
      ("XDG_STATE_HOME", home / "state"), ("XDG_CACHE_HOME", home / "cache"),
      ("XDG_RUNTIME_DIR", home / "run")])
    var args: seq[string]
    if op.arg("args").len > 0:
      args = op.arg("args").split('\0')
    let (code, output) = b.run(exe, args, home, env)
    OpResult(status: (if code == 0: osCompleted else: osFailed),
             detail: head & "exit=" & $code & " prefix=" &
               prefix.relativePath(if baseline: b.storeRoot
                                   else: b.previewStoreRoot),
             output: output.tail)
  except AgentRefusal as e:
    failed($e.reason & ": " & e.msg)
  except CheckoutError, KeyError, OSError:
    failed(getCurrentExceptionMsg())

# ---------------------------------------------------------------------
# Generations (M5).

method activeGeneration*(b: ReprobuildBackend): string =
  if b.driver.isNil: "" else: b.driver.current()

proc runHealthCheck(b: ReprobuildBackend; h: HealthCheck): tuple[ok: bool;
                                                               why: string] =
  ## One declared check against the generation that is now current. Home
  ## generations have launchers and files, not units or sockets: those
  ## kinds need a system generation and are refused, never skipped.
  let bin = b.driver.launcherDir()
  case h.kind
  of hcCommandExitZero:
    let argv = h.target.split(' ')
    let cmd = bin / argv[0]
    if argv[0].len == 0 or '/' in argv[0] or not fileExists(cmd):
      return (false, "no launcher " & argv[0].escape & " in the generation")
    let saved = b.timeoutSeconds
    b.timeoutSeconds = int(h.timeoutSeconds)
    defer: b.timeoutSeconds = saved
    let (code, output) = b.run(cmd, argv[1 .. ^1], bin, b.childEnv([]))
    if code != 0:
      return (false, "command-exit-zero " & h.target.escape & " exited " &
        $code & ": " & output.tail(512))
    (true, "")
  of hcPathExists:
    if not isCanonicalRelPath(h.target):
      return (false, "path-exists target is not a relative path")
    if not fileExists(bin.parentDir / h.target) and
        not dirExists(bin.parentDir / h.target):
      return (false, "path-exists " & h.target & " is missing")
    (true, "")
  of hcUnitActive, hcUnitNotFailed, hcSocketListening:
    (false, $h.kind & " needs a system generation")

proc stageChange(b: ReprobuildBackend; ws: Workspace; op: Operation): OpResult =
  let co = b.checkoutOf(ws)
  let diff = diffAgainstBase(co.root)
  let patch = recipeRelativePatch(diff, co.ownership.recipeName)
  let health = parseHealthChecks(op.arg("health"))
  # The interface identity of the ORIGINAL recipe: what the overlay
  # patches. Read from a pristine checkout, never from the edited one.
  let pristine = co.root / ".reproos-agent" / "pristine"
  removeDir(pristine)
  discard createCheckout(co.ownership, pristine, storeRoot = b.storeRoot)
  let graphEnv = b.childEnv([("REPRO_STORE_ROOT", b.previewStoreRoot)])
  let (gcode, graph) = b.run(b.reproExe, @["graph", "--format=json"],
                             pristine / co.ownership.recipeName, graphEnv)
  if gcode != 0:
    return failed("repro graph exited " & $gcode & ": " & graph.tail(1024))
  let identity = interfaceIdentityFromGraphJson(graph)
  # Build the change into the installed store, beside the original.
  let env = b.childEnv([("REPRO_STORE_ROOT", b.storeRoot),
                        ("REPRO_INSTALL_MIRROR_MODE", "hashed")])
  var args = @["build"]
  if op.arg("target").len > 0:
    args.add op.arg("target")
  let (code, output) = b.run(b.reproExe, args, co.packageDir, env)
  if code != 0:
    return OpResult(status: osFailed, detail: "repro " & args.join(" ") &
      " exited " & $code, output: output.tail)
  let rel = co.previewOutput
  if rel.len == 0 or rel == co.ownership.prefixPath.relativePath(b.storeRoot):
    return failed("the change built no new prefix")
  var parents: seq[Digest32]
  for hex in b.compositionParents.getOrDefault(ws.root, @[]):
    parents.add Digest32(b.staged[hex].releaseId)
  let m = draftManifest(co.ownership, identity, patch, op.arg("intent"),
                        currentRealizationPlatformTag(), health,
                        keyIdOf(b.remixKey), parents)
  let (rid, path) = writeOverlay(b.overlayRoot, m, patch, b.remixKey)
  let change = StagedChange(package: co.ownership.recipeName,
    baseGeneration: b.activeGeneration(), patch: patch,
    changedPaths: changedPathsOf(diff), prefixRel: rel,
    prefixPath: b.storeRoot / rel, releaseId: rid, manifestPath: path,
    healthChecks: m.healthChecks)
  b.staged[toHex(rid)] = change
  OpResult(status: osCompleted, detail: "release=" & toHex(rid) &
    " prefix=" & rel, output: patch)

proc activate(b: ReprobuildBackend; op: Operation): OpResult =
  if not b.staged.hasKey(op.target):
    return failed("no staged change " & op.target)
  let change = b.staged[op.target]
  let previous = b.driver.current()
  # The commit point (§"Cancellation"): cancelled before it, the active
  # generation is untouched; after it, the switch completes or rolls back.
  b.commit()
  let next = b.driver.switchTo(change)
  for h in change.healthChecks:
    let (ok, why) = b.runHealthCheck(h)
    if not ok:
      b.driver.rollbackTo(previous)
      return failed("health check failed (" & why & "); rolled back to " &
        "generation " & previous)
  OpResult(status: osCompleted, detail: "generation=" & next &
    " previous=" & previous)

method generation*(b: ReprobuildBackend; ws: Workspace;
                   op: Operation): OpResult =
  if b.driver.isNil:
    return failed("this host has no generation driver")
  try:
    case op.kind
    of okGenerationStage: b.stageChange(ws, op)
    of okGenerationActivate: b.activate(op)
    of okGenerationRollback:
      b.driver.rollbackTo(op.target)
      OpResult(status: osCompleted, detail: "generation=" & b.driver.current())
    else: failed("not a generation operation")
  except StageError, CheckoutError, RemixError, KeyError, OSError:
    failed(getCurrentExceptionMsg())

method remix*(b: ReprobuildBackend; ws: Workspace; op: Operation): OpResult =
  ## `remix.capture` keeps the staged overlay private (staging already
  ## stored it); `remix.export` writes its detached export bundle beside it.
  ## `remix.submit` needs the registry client and the user's credential
  ## handle, which this backend is not wired to.
  try:
    let rid = op.arg("release")
    if not b.staged.hasKey(rid):
      return failed("no staged change " & rid)
    let dir = b.staged[rid].manifestPath.parentDir
    case op.kind
    of okRemixCapture:
      OpResult(status: osCompleted, detail: "overlay=" & dir)
    of okRemixExport:
      let bundle = exportOverlay(dir)
      var s = newString(bundle.len)
      for i, x in bundle: s[i] = char(x)
      writeFile(dir / "export.bundle", s)
      OpResult(status: osCompleted, detail: "bundle=" & dir / "export.bundle")
    of okRemixSubmit:
      failed("registry submission is not wired to this backend")
    else: failed("not a remix operation")
  except RemixError, OSError, IOError:
    failed(getCurrentExceptionMsg())

method reapplyCheckout*(b: ReprobuildBackend; package, root: string;
                        op: Operation): OpResult =
  ## Check out `package` as the catalog has it NOW (after an upstream
  ## update its recipe resolves to a newer output) and re-apply a staged
  ## change's patch to it (M5 deliverable 4). A clean apply leaves the
  ## change ready to rebuild and retest; a conflict is reported hunk by hunk
  ## (`git apply --reject` keeps every hunk that applies and writes the rest
  ## to `.rej` files beside their targets) and the workspace is kept, so the
  ## agent can reapply the change semantically and revalidate it.
  try:
    let rid = op.arg("release")
    if not b.staged.hasKey(rid):
      return failed("no staged change " & rid)
    let change = b.staged[rid]
    let rec = b.ownershipFor(package)
    let co = createCheckout(rec, root, storeRoot = b.storeRoot)
    b.checkouts[root] = co
    let patchFile = root / ".reproos-agent" / "reapply.patch"
    writeFile(patchFile, change.patch)
    try:
      discard git(root, ["apply", "-p1", "--directory=" & rec.recipeName,
                         "--reject", "--whitespace=nowarn", patchFile])
      # The host replaces `detail` with the new workspace id, so the
      # outcome is the first line of `output`.
      OpResult(status: osCompleted,
               output: "reapply=clean\nbase=" & co.baseCommit & "\n")
    except CheckoutError as e:
      var rejects: seq[string]
      for p in walkDirRec(co.packageDir, relative = true):
        if p.endsWith(".rej"):
          rejects.add rec.recipeName & "/" & p
      OpResult(status: osCompleted,
               output: "reapply=conflict\nbase=" & co.baseCommit & "\n" &
                 "rejected=" & rejects.join(",") & "\n" & e.msg.tail(4096))
  except OwnershipError, CheckoutError, KeyError, OSError, IOError:
    failed(getCurrentExceptionMsg())

proc releaseDir(b: ReprobuildBackend; hex: string): string =
  b.staged[hex].manifestPath.parentDir

method composeCheckout*(b: ReprobuildBackend; package, root: string;
                        op: Operation): OpResult =
  ## Compose staged Remixes for `package` (M6). Every member is read back
  ## and verified from its overlay; composition is `repro_remix.compose`,
  ## with the blocked set as trust policy and no permission grant (a local
  ## change declares none). A blocked member or any unresolved conflict
  ## refuses with the conflicts named, before any workspace exists. A ready
  ## composition is checked out fresh with every member's patch applied in
  ## the composition's canonical order, ready to build, test and stage as a
  ## release whose parents are its members.
  try:
    var members: seq[MemberSpec]
    var hexes: seq[string]
    for hex in op.arg("releases").split(','):
      if hex.len == 0: continue
      if not b.staged.hasKey(hex):
        return failed("no staged change " & hex)
      let raw = readFile(b.staged[hex].manifestPath)
      var bytes = newSeq[byte](raw.len)
      for i, c in raw: bytes[i] = byte(ord(c))
      members.add MemberSpec(release: decodeAndVerify(bytes))
      hexes.add hex
    if members.len < 2:
      return failed("a composition needs at least two releases")
    let blockedSet = b.blocked
    let staged = b.staged
    let comp = compose(ComposeInputs(members: members,
      blobs: proc (id: Digest32): (bool, seq[byte]) =
        for hex, c in staged:
          let p = c.manifestPath.parentDir / "blobs" / toHex(id)
          if fileExists(p):
            let raw = readFile(p)
            var bytes = newSeq[byte](raw.len)
            for i, ch in raw: bytes[i] = byte(ord(ch))
            return (true, bytes)
        (false, newSeq[byte]()),
      parents: proc (id: ReleaseId): (bool, seq[Digest32]) =
        let hex = toHex(Digest32(id))
        if staged.hasKey(hex): (true, newSeq[Digest32]()) else: (false, newSeq[Digest32]()),
      isBlocked: proc (id: Digest32): bool = toHex(id) in blockedSet,
      admittedLicenses: @["LicenseRef-Local-Change"]))
    if comp.status != csReady:
      # Spec words, not enum identifiers: `patch conflict on <target>:<path>`.
      proc words(e: string; prefix: string): string =
        var name = e[prefix.len .. ^1]
        for i, ch in name:
          if ch in {'A'..'Z'}:
            if i > 0: result.add '-'
            result.add ch.toLowerAscii
          else:
            result.add ch
      var why: seq[string]
      for c in comp.conflicts:
        if c.resolvedBy < 0:
          why.add words($c.class, "cc") & " conflict on " & c.subject
      return failed("composition " & words($comp.status, "cs") & ": " &
                    why.join("; "))
    let rec = b.ownershipFor(package)
    let co = createCheckout(rec, root, storeRoot = b.storeRoot)
    b.checkouts[root] = co
    for i, step in comp.plan.patches:
      var found = false
      for hex in hexes:
        let p = b.releaseDir(hex) / "blobs" / toHex(step.patch.blob.id)
        if fileExists(p):
          let file = root / ".reproos-agent" / ("compose-" & $i & ".patch")
          copyFile(p, file)
          discard git(root, ["apply", "-p" & $step.patch.strip,
                             "--directory=" & rec.recipeName, file])
          found = true
          break
      if not found:
        return failed("composition patch blob " & toHex(step.patch.blob.id) &
          " is unavailable")
    b.compositionParents[root] = hexes
    var perms: seq[string]
    for p in comp.plan.permissions:
      perms.add $p.kind & (if p.scope.len > 0: ":" & p.scope else: "")
    OpResult(status: osCompleted, output: "composition=" & toHex(comp.id) &
      "\nmembers=" & hexes.sorted.join(",") &
      "\npermissions=" & perms.join(",") & "\n")
  except RemixError, OwnershipError, CheckoutError, KeyError, OSError, IOError:
    failed(getCurrentExceptionMsg())
