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

import std/[os, osproc, posix, strtabs, strutils, tables, times]

import repro_core/ambient_execution
import repro_agent_protocol
import repro_project_dsl/install_mirror_resolver

import ./[ownership, checkout, preview_strategy]

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
  ## deadline. Ambient by necessity for now (see `checkout.git`): the
  ## executables are the active generation's.
  let p = uncontrolledStartProcess(exe, workingDir = cwd, args = args,
                                   env = env, options = {poStdErrToStdOut})
  defer: p.close()
  var output = ""
  var buf: array[4096, char]
  let fd = cint(p.outputHandle)
  let deadline = epochTime() + float(b.timeoutSeconds)
  while true:
    if p.hasData:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n > 0:
        output.add buf.toOpenArray(0, n - 1).join("")
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
    sleep(10)
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
