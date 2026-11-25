## Shared-Development-Services D-SS11 (§4.6) and Ephemeral-State-Leases
## §4.6 — the SERVICE REGISTRY's records are updated under the record lock,
## so concurrent writers of one instance's records lose nothing.
##
## Before this, two consumers converging on one shared service could lose
## a consumer's contributed rows. Each of these is a read-modify-write of
## one state-store record:
##
##   * `depositServiceContributions` (a CONSUMER's `repro up`, in the
##     consumer's own process) reads the instance's contribution set,
##     replaces its own rows and writes the whole set back;
##   * `reconcileServiceRegistrations` and
##     `reconcileServiceInstanceAttributes` (the OWNER's converge) do the
##     same to the registrations record, each carrying the other's rows
##     forward.
##
## The atomic rename keeps every record whole, but without a per-record
## lock the last rename wins. Two consumers depositing at once then drop
## each other's rows, and the owner's next reconcile WITHDRAWS the dropped
## consumer's registrations (§5's withdrawal property): its OIDC client is
## deleted until it converges again. Two owner converges at once drop each
## other's attributes or registrations, and each calls the minter for
## members the other already registered.
##
## Every case drives the production procs from several processes (this
## binary re-executed) against one real state store, and checks what each
## writer can observe after its own write, plus the final record:
##
##   * (1) concurrent deposits by different contributors: after every
##     deposit, the depositor reads its own rows back; at the end every
##     contributor's LAST deposit is in the set;
##   * (2) a registrations reconcile and an attributes reconcile of one
##     instance at once: neither erases the other's rows;
##   * (3) two owner converges of one instance at once, converging the
##     same member set: every member is minted exactly once. (Two converges
##     with DIFFERENT member sets withdraw each other's members by design,
##     §5's withdrawal property, so they are not what this case measures.)
##
## MOCK POLICY — NO MOCKS. A real `StateStore` on a real filesystem, real
## instance keys through `serviceInstanceKey`, the real procs. The minter
## passed to `reconcileServiceRegistrations` is a parameter of that proc by
## design (`service_registry.nim` must not know how to talk to an issuer);
## the closure here has the CLI's development-registrar shape and also
## appends a line to a log, which is how case (3) counts mints across
## processes.

import std/[os, osproc, strtabs, strutils, unittest]

import repro_core/ambient_execution   # uncontrolledStartProcess
import repro_project_dsl
import repro_resources/service_identity
import repro_resources/service_registry

const ChildRoleEnv = "REPRO_SERVICE_REGISTRY_CONCURRENCY_CHILD"
const GoFileEnv = "REPRO_SERVICE_REGISTRY_CONCURRENCY_GO"
  ## A start barrier: every child waits for this file, which the parent
  ## creates once all of them are spawned, so a slow spawn cannot let one
  ## writer finish before another starts.

proc keyFor(root: string): ServiceInstanceKey =
  ## A real instance key, as `t_dss11_cross_process_contribution_store`
  ## derives it: a workspace-scoped stable identity under `root`.
  serviceInstanceKey(
    DslServiceDef(
      packageName: "srcowner", serviceName: "idp",
      identity: ServiceIdentityDef(kind: sikStable,
        stableId: "com.example.srconc.idp"),
      scope: sscWorkspace),
    ServiceScopeContext(projectRoot: canonicalRoot(root),
      workspaceRoot: canonicalRoot(root), workspaceId: "srconc-workspace",
      user: "srconctester"),
    [], "development")

proc scratch(sub: string): string =
  ## A throwaway root, removed by the suite's teardown.
  result = getTempDir() /
    ("repro-srconc-" & $getCurrentProcessId() & "-" & sub)
  removeDir(result)
  createDir(result)

proc loggingMinter(log: string): ServiceRegistrationMinter =
  result = proc (member, contributor: string): string {.closure.} =
    let f = open(log, fmAppend)
    try:
      f.write(member & "\n")
    finally:
      f.close()
    "mint-" & member

proc memberName(j: int): string = "rp" & $j

# ---------------------------------------------------------------------------
# Child roles (this binary re-executed). Each writes the number of times it
# found its own write undone to `<report>`, and exits 0.
# ---------------------------------------------------------------------------

proc childDeposit(root, contributor: string; count: int; report: string) =
  let key = keyFor(root)
  var lost = 0
  for j in 0 ..< count:
    let mine = contributor & "-m" & $j
    discard depositServiceContributions(root, key, contributor,
      [ServiceContribution(point: "relyingParties", contributor: contributor,
        operation: "coAppend", precedence: "epSet", members: @[mine],
        site: "recipe.nim:1")])
    var found = false
    for c in readServiceContributions(root, key).contributions:
      if c.contributor == contributor and c.members == @[mine]:
        found = true
    if not found: inc lost
  writeFile(report, $lost)

proc childRegistrations(root, log: string; count: int; report: string) =
  ## The owner's registration reconcile, with a member set that grows by
  ## one each iteration, so every iteration mints.
  let key = keyFor(root)
  var lost = 0
  for j in 0 ..< count:
    var members: seq[string] = @[]
    var contributors: seq[string] = @[]
    for i in 0 .. j:
      members.add(memberName(i))
      contributors.add("srcconsumer")
    discard reconcileServiceRegistrations(root, key, members, contributors,
      loggingMinter(log))
    let now = readServiceRegistrations(root, key)
    var have = 0
    for reg in now.registrations:
      if reg.member in members: inc have
    if have < members.len: inc lost
  writeFile(report, $lost)

proc childConvergeRounds(root, log: string; rounds, members: int) =
  ## One owner converge per ROUND, each round a fresh instance (its own store
  ## root), each converging the SAME member set. The two children run this
  ## loop side by side, so they keep meeting on the same round: the first
  ## mints, the second must find those rows and reuse them.
  for r in 0 ..< rounds:
    let roundRoot = root / ("round-" & $r)
    createDir(roundRoot)
    var ms: seq[string] = @[]
    var cs: seq[string] = @[]
    for i in 0 ..< members:
      ms.add("round" & $r & "-" & memberName(i))
      cs.add("srcconsumer")
    discard reconcileServiceRegistrations(roundRoot, keyFor(roundRoot), ms,
      cs, loggingMinter(log))

proc childAttributes(root: string; count: int; report: string) =
  let key = keyFor(root)
  var lost = 0
  for j in 0 ..< count:
    let value = "http://127.0.0.1:" & $(20000 + j)
    discard reconcileServiceInstanceAttributes(root, key,
      [(name: "issuer", value: value)])
    var found = false
    for a in readServiceRegistrations(root, key).attributes:
      if a.name == "issuer" and a.value == value: found = true
    if not found: inc lost
  writeFile(report, $lost)

if existsEnv(ChildRoleEnv):
  let args = commandLineParams()
  var waited = 0
  while not fileExists(getEnv(GoFileEnv)):
    if waited > 60_000: quit("start barrier never opened", 4)
    sleep(5)
    waited += 5
  case getEnv(ChildRoleEnv)
  of "deposit":
    childDeposit(args[0], args[1], parseInt(args[2]), args[3])
  of "registrations":
    childRegistrations(args[0], args[1], parseInt(args[2]), args[3])
  of "converge-rounds":
    childConvergeRounds(args[0], args[1], parseInt(args[2]),
      parseInt(args[3]))
  of "attributes":
    childAttributes(args[0], parseInt(args[1]), args[2])
  else:
    quit("unknown child role", 2)
  quit(0)

proc spawnChild(role: string; args: openArray[string]): Process =
  ## `args[0]` is the case's scratch root; its barrier file is beside it.
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env[ChildRoleEnv] = role
  env[GoFileEnv] = args[0] / "go"
  uncontrolledStartProcess(getAppFilename(), args = args, env = env,
    options = {poParentStreams})

proc release(root: string) =
  ## Open the start barrier for every child of the case under `root`.
  writeFile(root / "go", "")

proc lostIn(reports: openArray[string]): int =
  for r in reports:
    result += parseInt(readFile(r).strip())

suite "service registry records are updated under the record lock":

  var roots: seq[string] = @[]

  teardown:
    for r in roots: removeDir(r)
    roots = @[]

  test "(1) concurrent deposits by different contributors lose no row":
    let root = scratch("deposit")
    roots.add(root)
    const Writers = 6
    const PerWriter = 40
    var children: seq[Process] = @[]
    var reports: seq[string] = @[]
    for i in 0 ..< Writers:
      reports.add(root / ("report-" & $i))
      children.add(spawnChild("deposit",
        [root, "consumer" & $i, $PerWriter, reports[^1]]))
    release(root)
    for p in children:
      check p.waitForExit() == 0
      p.close()
    let lost = lostIn(reports)
    checkpoint("deposits found undone by another writer: " & $lost &
      " of " & $(Writers * PerWriter))
    check lost == 0
    let final = readServiceContributions(root, keyFor(root))
    var missing: seq[string] = @[]
    for i in 0 ..< Writers:
      let want = "consumer" & $i & "-m" & $(PerWriter - 1)
      var found = false
      for c in final.contributions:
        if c.contributor == "consumer" & $i and c.members == @[want]:
          found = true
      if not found: missing.add("consumer" & $i)
    checkpoint("contributors whose last deposit is missing: " &
      missing.join(","))
    check missing.len == 0
    check final.contributions.len == Writers

  test "(2) a registrations and an attributes reconcile keep each other's rows":
    let root = scratch("regattr")
    roots.add(root)
    const PerWriter = 40
    let regReport = root / "report-reg"
    let attrReport = root / "report-attr"
    let children = @[
      spawnChild("registrations",
        [root, root / "mints", $PerWriter, regReport]),
      spawnChild("attributes", [root, $PerWriter, attrReport])]
    release(root)
    for p in children:
      check p.waitForExit() == 0
      p.close()
    let regLost = lostIn([regReport])
    let attrLost = lostIn([attrReport])
    checkpoint("registration reconciles undone: " & $regLost &
      "; attribute reconciles undone: " & $attrLost)
    check regLost == 0
    check attrLost == 0
    let final = readServiceRegistrations(root, keyFor(root))
    check final.registrations.len == PerWriter
    check final.attributes.len == 1
    if final.attributes.len == 1:
      check final.attributes[0].value ==
        "http://127.0.0.1:" & $(20000 + PerWriter - 1)

  test "(3) two owner converges of one instance mint each member once":
    let root = scratch("mintonce")
    roots.add(root)
    const Rounds = 60
    const Members = 4
    let log = root / "mints"
    writeFile(log, "")
    let children = @[
      spawnChild("converge-rounds", [root, log, $Rounds, $Members]),
      spawnChild("converge-rounds", [root, log, $Rounds, $Members])]
    release(root)
    for p in children:
      check p.waitForExit() == 0
      p.close()
    var minted: seq[string] = @[]
    var seen: seq[string] = @[]
    var twice: seq[string] = @[]
    for line in readFile(log).splitLines():
      if line.len == 0: continue
      minted.add(line)
      if line in seen: twice.add(line) else: seen.add(line)
    checkpoint("mints: " & $minted.len & " for " & $(Rounds * Members) &
      " members; minted more than once: " & $twice.len)
    check twice.len == 0
    check minted.len == Rounds * Members
    for r in 0 ..< Rounds:
      let roundRoot = root / ("round-" & $r)
      check readServiceRegistrations(roundRoot,
        keyFor(roundRoot)).registrations.len == Members
