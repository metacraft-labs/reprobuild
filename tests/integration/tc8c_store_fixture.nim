## TC-8c shared fixture: a real workspace, a real developer clone, a real
## upstream bare and (optionally) a real gateway bare, with the local
## certificate store pointed at scratch roots.
##
## ``include``d (not imported, not a registered test) by the TC-8c integration
## tests. Every git operation runs real git; every certificate the fixture
## signs is signed by the real ``ssh-keygen`` path issuance uses, with a key
## registered in the workspace's registered-keys store.
##
## Isolation: ``setupStoreFixture`` points ``TEST_CERTIFICATES_DIR`` and
## ``TEST_CERTIFICATES_SYSTEM_DIR`` at the fixture's scratch directory in this
## process's environment, so every child — ``repro test``, ``repro check``,
## ``repro ci plan``, the hooks a ``git push`` runs — reads and writes those
## roots and never the user's own. Each test case runs as its own process.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_lock
import repro_workspace_manifests
import repro_lock/certificate_policy
import ./every_branch_policy

include tc5_cert_signing_helpers

const storeKeyId = "tc8c-daemon-key"

type
  StoreFixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    upstreamBare: string   ## the real upstream (stands in for GitHub)
    gatewayBare: string    ## the daemon-managed gateway bare
    libAPath: string       ## the developer's clone
    seedSha: string
    daemonKey: string      ## the ed25519 private key issuance signs with
    userRoot: string       ## TEST_CERTIFICATES_DIR
    systemDir: string      ## TEST_CERTIFICATES_SYSTEM_DIR
    systemRoot: string     ## <systemDir>/<uid>

proc runArgv(argv: seq[string]; cwd = "";
             env: seq[tuple[name, value: string]] = @[]):
    tuple[code: int; output: string] =
  ## Run an argv (no shell string), stdout and stderr merged.
  let res = runShell(shellCommand(argv, env),
    if cwd.len > 0: cwd else: getCurrentDir())
  (res.code, res.output)

proc gitOut(dir: string; args: varargs[string]): string =
  ## ``git -C dir args`` that must succeed; its stripped output.
  var argv = @["git", "-C", dir]
  for a in args: argv.add(a)
  let res = execCmdEx(quoteShellCommand(argv))
  doAssert res.exitCode == 0, argv.join(" ") & " failed:\n" & res.output
  res.output.strip()

proc storeRepoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc storeReproBinary(): string =
  requireBinary(storeRepoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const storeLibAFragment = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
"""

proc storeProjectToml(libAUrl: string): string =
  ## The project manifest. It carries no certificate policy: since TC-9d the
  ## policy lives in lib-a's own ``repro.lock`` (``setupStoreFixture``).
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

proc requiredPolicy*(targets: seq[string]; platforms: seq[string];
                     mode = "required"; ciTrust = "";
                     untrackedInputs = ""): string =
  ## The ``[certificate_policy]`` snapshot of a policy with one rule for
  ## every branch (``everyBranchPolicy``): ``targets`` on ``platforms`` under
  ## ``mode``. ``setupStoreFixture`` commits it in lib-a's ``repro.lock``.
  let policyMode =
    case mode
    of "required": pmRequired
    of "advisory": pmAdvisory
    else: pmOff
  everyBranchSnapshot(policyMode, targets, platforms,
    ciTrust = (if ciTrust == "skip": pctSkip else: pctAdvisory),
    untrackedInputs =
      (if untrackedInputs == "strict": puiStrict else: puiReadSet),
    name = "lib-a")

proc policyLock*(snapshot: string): string =
  ## A committed ``repro.lock`` that pins nothing and carries ``snapshot``
  ## ("" for none), laid out as the lock writer lays it out.
  let lock = serializeLockedDependencies(LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2", deps: @[]))
  replaceCertificatePolicySection(lock, snapshot)

proc committedLockBody*(revision: string): string =
  ## A real committed ``repro.lock``, written by the real serializer.
  serializeLockedDependencies(LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    deps: @[LockedDep(
      name: "lib-a", path: ".",
      coordinates: Coordinates(kind: ckVcs, gitRef: "main",
        revision: revision),
      integrity: "git-sha1:" & revision,
      visibility: "public")]))

proc setupStoreFixture(policySnapshot: string; slug: string;
                       recordStore = true;
                       committedLock = false): StoreFixture =
  ## ``policySnapshot``: a ``[certificate_policy]`` snapshot (``requiredPolicy``)
  ## the seed commit records in lib-a's ``repro.lock`` -- the only place a
  ## gate reads a policy from since TC-9d, a record-store project included
  ## -- or "" for none.
  ## ``recordStore``: the workspace declares a manifest-backed lock route (the
  ## record-store opt-in), which issuance on the ``repro test`` path needs.
  ## ``committedLock``: lib-a tracks a ``repro.lock`` pinning itself (with
  ## no policy and no ``committedLock``, lib-a tracks no ``repro.lock``).
  result.scratch = createTempDir("repro-tc8c-" & slug & "-", "")
  result.userRoot = result.scratch / "store-user"
  result.systemDir = result.scratch / "store-system"
  result.systemRoot = result.systemDir / $nativeStoreAccount()
  putEnv("TEST_CERTIFICATES_DIR", result.userRoot)
  putEnv("TEST_CERTIFICATES_SYSTEM_DIR", result.systemDir)
  result.reproBin = storeReproBinary()
  result.upstreamBare = result.scratch / "upstream-lib-a.git"
  result.gatewayBare = result.scratch / "gateway-lib-a.git"

  let seed = result.scratch / "seed-lib-a"
  discard gitOut(result.scratch, "init", "--bare", "-b", "main",
    result.upstreamBare)
  discard gitOut(result.scratch, "init", "-b", "main", seed)
  discard gitOut(seed, "config", "user.email", "tester@example.invalid")
  discard gitOut(seed, "config", "user.name", "TC8c Seeder")
  writeFile(seed / "README.md", "TC-8c fixture\n")
  if committedLock:
    writeFile(seed / "repro.lock", replaceCertificatePolicySection(
      committedLockBody("1".repeat(40)), policySnapshot))
  elif policySnapshot.len > 0:
    writeFile(seed / "repro.lock", policyLock(policySnapshot))
  discard gitOut(seed, "add", "-A")
  discard gitOut(seed, "commit", "-m", "seed")
  discard gitOut(seed, "remote", "add", "origin", result.upstreamBare)
  discard gitOut(seed, "push", "origin", "main")
  result.seedSha = gitOut(seed, "rev-parse", "HEAD")

  let ws = result.scratch / "workspace"
  createDir(ws / "projects")
  createDir(ws / "repos")
  writeFile(ws / "repos" / "lib-a.toml", storeLibAFragment)
  writeFile(ws / "projects" / "lib-a.toml",
    storeProjectToml(fileUrl(result.upstreamBare)))
  result.workspaceRoot = ws
  if recordStore:
    seedManifestLockStore("git", ws)
  result.libAPath = ws / "lib-a"
  discard gitOut(result.scratch, "clone", fileUrl(result.upstreamBare),
    result.libAPath)
  discard gitOut(result.libAPath, "config", "user.email",
    "tester@example.invalid")
  discard gitOut(result.libAPath, "config", "user.name", "TC8c Tester")
  writeWorkspaceBranch(ws, project = "lib-a", branch = "main")

  let key = genEd25519Key(result.scratch / "daemon-keys", "tc8c-key",
    storeKeyId)
  result.daemonKey = key.priv
  writeRegistry(ws,
    @[RegisteredKey(keyId: storeKeyId, publicKey: key.pub, status: rksActive)])

proc seedLock(fx: StoreFixture) =
  let res = runArgv(@[fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot])
  if res.code != 0:
    checkpoint("workspace lock failed: " & res.output)
  check res.code == 0

proc newCommit(fx: StoreFixture; file, body: string): string =
  writeFile(fx.libAPath / file, body)
  discard gitOut(fx.libAPath, "add", file)
  discard gitOut(fx.libAPath, "commit", "-m", "change " & file)
  gitOut(fx.libAPath, "rev-parse", "HEAD")

proc writeFixtureJson(path: string; selectors: seq[string]) =
  var obj = newJObject()
  obj["fallbackBuildCostNs"] = %1
  obj["fallbackTestCostNs"] = %1
  var edges = newJArray()
  for i, selector in selectors:
    var e = newJObject()
    e["id"] = %(i + 1)
    e["selector"] = %selector
    e["historyKey"] = %selector
    e["buildDeps"] = newJArray()
    e["runCmd"] = %["sh", "-c", "exit 0"]
    e["testName"] = %selector
    edges.add(e)
  obj["testEdges"] = edges
  obj["buildActions"] = newJArray()
  createDir(path.parentDir)
  writeFile(path, obj.pretty() & "\n")

proc issueViaReproTest(fx: StoreFixture; selectors = @["t-unit"];
                       extra: seq[string] = @[];
                       env: seq[tuple[name, value: string]] = @[]):
    tuple[code: int; output: string] =
  ## The real issuance path: ``repro test --certify`` on a passing fixture.
  let fixtureJson = fx.scratch / "fixtures" / (selectors.join("-") & ".json")
  writeFixtureJson(fixtureJson, selectors)
  var argv = @[fx.reproBin, "test", "--fixture-from=" & fixtureJson,
    "--shard=1/1", "--certify", "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath]
  for a in extra: argv.add(a)
  runArgv(argv, fx.workspaceRoot, daemonKeyEnv(fx.daemonKey, storeKeyId) & env)

proc signedCertFor(fx: StoreFixture; content, base: string;
                   targets = @["t-unit"];
                   platform = currentPlatformTag()): TestCertificate =
  ## A certificate for ``content`` signed by the fixture's registered daemon
  ## key through the real signing primitive (``ssh-keygen -Y sign``).
  result = TestCertificate(
    schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId,
    project: "lib-a", platform: platform, targets: targets,
    result: tcrPassed, issuedAt: "2026-10-11T00:00:00Z",
    issuer: "tc8c-fixture",
    vcs: TestCertificateVcs(repo: "lib-a", content: content,
      untracked: false, base: base),
    commands: @[TestCertificateCommand(argv: @["sh", "-c", "exit 0"])])
  signCertificateOnIssuance(result, storeKeyId, fx.daemonKey)

proc checkPrePush(fx: StoreFixture; sha: string):
    tuple[code: int; output: string; report: JsonNode] =
  ## The client pre-push gate, as the managed hook runs it.
  let refs = fx.scratch / "pushed-refs.txt"
  writeFile(refs, "refs/heads/main " & sha & " refs/heads/main " &
    "0".repeat(40) & "\n")
  let res = runArgv(@[fx.reproBin, "check", "--mode=pre-push",
    "--write-report", "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath, "--pushed-refs=" & refs, "--json"])
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "check-report.json"
  let report =
    if fileExists(reportPath): parseFile(reportPath) else: newJObject()
  (res.code, res.output, report)

proc failureProperties(report: JsonNode): seq[string] =
  if report.hasKey("failures"):
    for f in report["failures"]:
      result.add(f["property"].getStr())

proc noticesText(report: JsonNode): string =
  if report.hasKey("notices"):
    for n in report["notices"]:
      result.add(n.getStr() & "\n")

proc wireStoreGateway(fx: StoreFixture; registeredKeys = "") =
  ## Wire the developer clone's push URL to a gateway bare (record-store
  ## lock source) forwarding to the upstream bare. The gateway applies the
  ## policy the PUSHED tree records in its ``repro.lock`` (TC-9d): the
  ## fixture's ``policySnapshot``.
  let cfg = GatewayConfig(
    lockRecordsDir: lockRecordsDirFor(
      fx.workspaceRoot / ".repro" / "manifests", "lib-a", "lib-a"),
    registeredKeysPath:
      if registeredKeys.len > 0: registeredKeys
      else: registeredKeyStorePath(fx.workspaceRoot))
  let wired = wirePushGateway("git", fx.libAPath, fx.gatewayBare,
    fileUrl(fx.upstreamBare), cfg)
  doAssert wired.ok, wired.diagnostic

proc pushToGateway(fx: StoreFixture; refspecs: seq[string]):
    tuple[code: int; output: string] =
  ## ``git push --no-verify origin <refspecs>`` through the gateway, with the
  ## gateway hooks pointed at the freshly built ``repro``.
  runArgv(@["git", "-C", fx.libAPath, "push", "--no-verify", "origin"] &
    refspecs, env = @[(name: "REPROBUILD_REPRO", value: fx.reproBin)])

proc upstreamTip(fx: StoreFixture): string =
  let res = execCmdEx(quoteShellCommand(@["git", "-C", fx.upstreamBare,
    "rev-parse", "refs/heads/main"]))
  if res.exitCode != 0: "" else: res.output.strip()

proc ciPlan(fx: StoreFixture; platform: string): JsonNode =
  let res = runArgv(@[fx.reproBin, "ci", "plan", "--platform=" & platform,
    "--workspace-root=" & fx.workspaceRoot, "--current-repo=" & fx.libAPath,
    "--json"])
  checkpoint("ci plan output:\n" & res.output)
  doAssert res.code == 0, "repro ci plan failed:\n" & res.output
  let start = res.output.find("{\n")
  doAssert start >= 0, "no JSON in ci plan output:\n" & res.output
  parseJson(res.output[start .. ^1])

proc planPlatform(plan: JsonNode; platform: string): JsonNode =
  for p in plan["platforms"]:
    if p["platform"].getStr() == platform:
      return p
  doAssert false, "platform not in plan: " & platform

proc strings(node: JsonNode; key: string): seq[string] =
  if node.hasKey(key):
    for x in node[key]: result.add(x.getStr())

proc workingTreeContentId(repo: string): string =
  ## The working tree's content id, computed by git itself: every tracked
  ## file's working-tree content in a temporary index, ``git write-tree``.
  let index = createTempDir("tc8c-index-", "") / "index"
  copyFile(repo / ".git" / "index", index)
  let env = @[(name: "GIT_INDEX_FILE", value: index)]
  let added = runArgv(@["git", "-C", repo, "add", "--update"], env = env)
  doAssert added.code == 0, added.output
  let tree = runShell(shellCommand(@["git", "-C", repo, "write-tree"], env))
  doAssert tree.code == 0, tree.output
  removeDir(index.parentDir)
  "git-tree-sha1:" & tree.output.strip()
