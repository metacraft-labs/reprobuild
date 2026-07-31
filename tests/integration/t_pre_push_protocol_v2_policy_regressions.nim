## Pre-push protocol v2 — publication-policy regression ordering.
##
## A real two-repo dependency closure is pushed through installed hooks. The
## current app HEAD may receive ``outgoing-current`` only after strict protocol
## validation; dirty-current, unpublished/dirty dependency, and dirty develop
## override stages refuse before any lock is written. Required-certificate and
## lock-integrity failures also refuse before source publication. A preserved
## user-hook failure precedes the managed body. An externally supplied
## capability token fails closed and cannot skip either hook, while the retired
## boolean sentinel is scrubbed and has no bypass effect. Distinct real
## external-CLI backend runs prove a shared failure refuses while the same
## personal/private failure warns and allows, with operation markers ordered
## before the source result. The final ordinary push succeeds, demonstrating
## that refusal cases did not weaken or disable the gate. The two-node topology
## and process sequence run on every supported OS with Git; any premature lock
## write or source-remote advance falsifies ordering. All pushes use local bare
## remotes, and no hook, policy stage, or filesystem boundary is mocked.

import std/[json, options, os, sequtils, strutils, tempfiles, unittest]

when not defined(windows):
  import std/osproc

import git_tool
import repro_cli_support
import repro_cli_support/push_hook_protocol
import repro_lock_store
import repro_test_support
import repro_workspace_manifests

const
  ExternalStoreModeEnv = "REPROBUILD_TEST_POLICY_STORE_MODE"
  ExternalStoreLogEnv = "REPROBUILD_TEST_POLICY_STORE_LOG"

# Windows cannot execute the POSIX shell store fixtures directly through the
# production external-CLI backend's CreateProcess boundary. Re-execute this
# native test binary as the same tiny get/put store there; POSIX retains the
# shell fixture below. The helper is selected only by a test-private env var.
if getEnv(ExternalStoreModeEnv).len > 0:
  if paramCount() != 2:
    quit 74
  let op = paramStr(1)
  let key = paramStr(2)
  let log = getEnv(ExternalStoreLogEnv)
  if log.len == 0:
    quit 75
  var logFile = open(log, fmAppend)
  logFile.writeLine(op & " " & key)
  logFile.close()
  if op == "get":
    stdout.write("{\"schema\":\"reprobuild.lockstore.external-cli.v1\"," &
      "\"found\":false}")
    quit 0
  if op != "put":
    quit 76
  discard stdin.readAll()
  if getEnv(ExternalStoreModeEnv) == "fail":
    quit 73
  stdout.write("{\"schema\":\"reprobuild.lockstore.external-cli.v1\"," &
    "\"outcome\":\"ok\"}")
  quit 0

proc q(value: string): string =
  when defined(windows):
    # Command strings are evaluated by Git-for-Windows sh (see run below).
    # Quote even space-free drive paths so backslashes remain literal.
    "'" & value.replace("'", "'\"'\"'") & "'"
  else:
    quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  when defined(windows):
    let shell = findExe("sh")
    if shell.len == 0:
      return (127, "Git hook shell is unavailable")
    let res = runShell(shellCommand(@[shell, "-c", command]))
    (res.code, res.output)
  else:
    let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
    (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1
  res.output

proc root(): string = currentSourcePath().parentDir.parentDir.parentDir
proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  let candidate =
    if configured.len > 0: configured
    else: root() / "build" / "bin" / addFileExt("repro", ExeExt)
  requireBinary(candidate, "reprobuild.apps.repro")

proc executable(path, content: string) =
  writeFile(path, content)
  var permissions = getFilePermissions(path)
  permissions.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, permissions)

type Fixture = object
  scratch, workspace, app, dep, appOrigin, depOrigin, reproBin: string

proc seed(gitBin, origin, seedPath: string) =
  discard require(q(gitBin) & " init --bare -b main " & q(origin))
  discard require(q(gitBin) & " init -b main " & q(seedPath))
  discard require(q(gitBin) & " -C " & q(seedPath) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(seedPath) &
    " config user.name 'Policy Tester'")
  writeFile(seedPath / "README.md", "seed\n")
  discard require(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard require(q(gitBin) & " -C " & q(seedPath) & " commit -m seed")
  discard require(q(gitBin) & " -C " & q(seedPath) &
    " remote add origin " & q(origin))
  discard require(q(gitBin) & " -C " & q(seedPath) & " push origin main")

proc setup(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-pre-push-policy-v2-", "")
  result.workspace = result.scratch / "workspace"
  result.app = result.workspace / "app"
  result.dep = result.workspace / "dep"
  result.appOrigin = result.scratch / "app.git"
  result.depOrigin = result.scratch / "dep.git"
  result.reproBin = reproBinary()
  seed(gitBin, result.appOrigin, result.scratch / "app-seed")
  seed(gitBin, result.depOrigin, result.scratch / "dep-seed")
  createDir(result.workspace)
  discard require(q(gitBin) & " clone " & q(result.appOrigin) & " " &
    q(result.app))
  discard require(q(gitBin) & " clone " & q(result.depOrigin) & " " &
    q(result.dep))
  for repo in [result.app, result.dep]:
    discard require(q(gitBin) & " -C " & q(repo) &
      " config user.email tester@example.invalid")
    discard require(q(gitBin) & " -C " & q(repo) &
      " config user.name 'Policy Tester'")
  let manifests = result.workspace / ".repro" / "manifests"
  createDir(manifests / "projects")
  createDir(manifests / "repos")
  writeFile(result.workspace / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\nbranch = \"main\"\n")
  writeFile(manifests / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" &
      result.appOrigin.replace('\\', '/') & "\"\n\n" &
    "[[remote]]\nname = \"dep-origin\"\nfetch = \"" &
      result.depOrigin.replace('\\', '/') & "\"\n\n" &
    "includes = [\"repos/app.toml\", \"repos/dep.toml\"]\n")
  writeFile(manifests / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"app-origin\"\nrevision = \"main\"\n" &
    "depends = [\"dep\"]\n")
  writeFile(manifests / "repos" / "dep.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"dep\"\npath = \"dep\"\n" &
    "remote = \"dep-origin\"\nrevision = \"main\"\n")
  let ensured = runShell(shellCommand(@[result.reproBin, "hooks", "ensure",
    "--vcs", "--workspace-root=" & result.workspace, result.workspace]))
  if ensured.code != 0:
    checkpoint(ensured.output)
    quit 1
  # Keep this suite about pre-push ordering; prevent post-commit refresh from
  # manufacturing locks before the pre-push boundary.
  for repo in [result.app, result.dep]:
    for name in ["post-commit", "post-merge", "post-checkout"]:
      for suffix in ["", ".repro-managed", ".repro-local"]:
        let path = repo / ".git" / "hooks" / (name & suffix)
        if fileExists(path): removeFile(path)

proc commit(gitBin, repo, label: string): string =
  writeFile(repo / (label & ".txt"), label & "\n")
  discard require(q(gitBin) & " -C " & q(repo) & " add " & q(label & ".txt"))
  discard require(q(gitBin) & " -C " & q(repo) & " commit -m " & q(label))
  require(q(gitBin) & " -C " & q(repo) & " rev-parse HEAD").strip()

proc bareHead(gitBin, bare: string): string =
  require(q(gitBin) & " --git-dir=" & q(bare) &
    " rev-parse refs/heads/main").strip()

proc initGitStore(gitBin, path: string) =
  discard require(q(gitBin) & " init -b main " & q(path))
  discard require(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(path) &
    " config user.name 'Policy Tester'")
  writeFile(path / "README.md", "lock store\n")
  discard require(q(gitBin) & " -C " & q(path) & " add README.md")
  discard require(q(gitBin) & " -C " & q(path) & " commit -m seed")

proc report(fx: Fixture): JsonNode =
  parseFile(fx.workspace / ".repro" / "build" / "reports" / "check-report.json")

proc hasFailure(report: JsonNode; property: string): bool =
  if not report.hasKey("failures"): return false
  for failure in report["failures"]:
    if failure.hasKey("property") and
        failure["property"].getStr() == property:
      return true

proc writeDevelopOverride(workspace, package, path: string) =
  createDir(workspace / ".repro")
  writeFile(workspace / ".repro" / "develop-overrides.toml",
    "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
    "[[override]]\npackage = \"" & package & "\"\nlocal_path = \"" &
      path.replace('\\', '/') & "\"\nstate = \"editable\"\n" &
    "created_at = \"2026-07-22T00:00:00Z\"\n")

proc requiredCertificateProject(body: string): string =
  let remote = body.find("[[remote]]")
  if remote < 0: return body
  body[0 ..< remote] &
    "[certificates]\ngate_mode = \"required\"\n" &
    "required_targets = [\"t-unit\"]\nrequired_platforms = [\"" &
    hostOS & "/" & hostCPU & "\"]\n\n" & body[remote .. ^1]

proc writeFailingStore(path, log: string) =
  when defined(windows):
    copyFile(getAppFilename(), path)
    putEnv(ExternalStoreModeEnv, "fail")
    putEnv(ExternalStoreLogEnv, log)
  else:
    executable(path,
      "#!/usr/bin/env sh\nset -eu\n" &
      "op=${1:-}; key=${2:-}\nprintf '%s %s\\n' \"$op\" \"$key\" >> " &
        q(log) & "\n" &
      "if [ \"$op\" = get ]; then " &
        "printf '%s' '{\"schema\":\"reprobuild.lockstore.external-cli.v1\"," &
        "\"found\":false}'; exit 0; fi\n" &
      "cat >/dev/null\nexit 73\n")

proc writeRecordingStore(path, log: string) =
  when defined(windows):
    copyFile(getAppFilename(), path)
    putEnv(ExternalStoreModeEnv, "record")
    putEnv(ExternalStoreLogEnv, log)
  else:
    executable(path,
      "#!/usr/bin/env sh\nset -eu\n" &
      "op=${1:-}; key=${2:-}; printf '%s %s\\n' \"$op\" \"$key\" >> " &
        q(log) & "\n" &
      "if [ \"$op\" = get ]; then " &
        "printf '%s' '{\"schema\":\"reprobuild.lockstore.external-cli.v1\"," &
        "\"found\":false}'; exit 0; fi\n" &
      "cat >/dev/null\n" &
      "printf '%s' '{\"schema\":\"reprobuild.lockstore.external-cli.v1\"," &
        "\"outcome\":\"ok\"}'\n")

proc nativeRoutingConfig(workspace: string): string =
  workspace / ".repro" / "config.toml"

type
  EnvSnapshot = object
    existed: bool
    value: string

  RoutingConfigEnvironment = object
    system: EnvSnapshot
    user: EnvSnapshot
    vcsPrivate: EnvSnapshot

proc snapshotEnv(name: string): EnvSnapshot =
  EnvSnapshot(existed: existsEnv(name), value: getEnv(name))

proc restoreEnv(name: string; snapshot: EnvSnapshot) =
  if snapshot.existed:
    putEnv(name, snapshot.value)
  else:
    delEnv(name)

proc snapshotRoutingConfig(): RoutingConfigEnvironment =
  ## Snapshot every variable before changing any of them. In particular,
  ## present-but-empty values are distinct from absent values.
  result.system = snapshotEnv("REPROBUILD_SYSTEM_CONFIG")
  result.user = snapshotEnv("REPROBUILD_USER_CONFIG")
  result.vcsPrivate = snapshotEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc restoreRoutingConfig(environment: RoutingConfigEnvironment) =
  restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", environment.vcsPrivate)
  restoreEnv("REPROBUILD_USER_CONFIG", environment.user)
  restoreEnv("REPROBUILD_SYSTEM_CONFIG", environment.system)

proc isolateRoutingConfig(scratch, workspace: string):
    RoutingConfigEnvironment =
  ## Keep all layered config reads inside this fixture. If an override itself
  ## raises, roll back the already-written variables before propagating.
  result = snapshotRoutingConfig()
  try:
    putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
    putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
    putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", nativeRoutingConfig(workspace))
  except:
    restoreRoutingConfig(result)
    raise

proc failAfterRoutingIsolation(scratch, workspace: string) =
  ## Exercise the same immediate-defer pattern used by the real fixtures.
  let environment = isolateRoutingConfig(scratch, workspace)
  defer: restoreRoutingConfig(environment)
  doAssert getEnv("REPROBUILD_SYSTEM_CONFIG") == scratch / "no-system.toml"
  doAssert getEnv("REPROBUILD_USER_CONFIG") == scratch / "no-user.toml"
  doAssert getEnv("REPROBUILD_VCS_PRIVATE_CONFIG") ==
    nativeRoutingConfig(workspace)
  raise newException(ValueError, "routing isolation teardown probe")

proc writeNativeRoutingConfig(workspace, routes: string) =
  createDir(workspace / ".repro")
  writeFile(nativeRoutingConfig(workspace),
    "schema = \"reprobuild.config.v1\"\n\n" &
    "[locking]\nroute = [" & routes & "]\n")

proc manifestProject(name: string; remotes: seq[(string, string)];
    includes: seq[string]):
    string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & name &
    "\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n"
  for remote in remotes:
    result.add("[[remote]]\nname = \"" & remote[0] & "\"\nfetch = \"" &
      remote[1].replace('\\', '/') & "\"\n\n")
  result.add("includes = [")
  for i, includePath in includes:
    if i > 0: result.add(", ")
    result.add("\"" & includePath & "\"")
  result.add("]\n")

proc manifestRepo(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\nname = \"" &
    name & "\"\npath = \"" & name & "\"\nremote = \"" & remote &
    "\"\nrevision = \"main\"\n"

proc seedManifestLayer(gitBin, layer, bare: string;
    files: openArray[(string, string)]) =
  discard require(q(gitBin) & " init --bare -b main " & q(bare))
  discard require(q(gitBin) & " init -b main " & q(layer))
  discard require(q(gitBin) & " -C " & q(layer) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(layer) &
    " config user.name 'Policy Tester'")
  for entry in files:
    let path = layer / entry[0]
    createDir(path.parentDir())
    writeFile(path, entry[1])
  discard require(q(gitBin) & " -C " & q(layer) & " add -A")
  discard require(q(gitBin) & " -C " & q(layer) & " commit -m seed")
  discard require(q(gitBin) & " -C " & q(layer) &
    " remote add origin " & q(bare))
  discard require(q(gitBin) & " -C " & q(layer) &
    " push -u origin main")

proc mixedVisibilityLock(appSha, depSha, secretSha: string): string =
  "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
    "[lock]\nproject = \"app\"\n" &
    "created_at = \"2026-07-22T00:00:00Z\"\n" &
    "created_by = \"protocol v2 policy fixture\"\n" &
    "workspace_branch = \"main\"\n\n" &
    "[[repo]]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"app-origin\"\nrevision = \"" & appSha & "\"\n\n" &
    "[[repo]]\nname = \"dep\"\npath = \"dep\"\n" &
    "remote = \"dep-origin\"\nrevision = \"" & depSha & "\"\n\n" &
    "[[repo]]\nname = \"secret\"\npath = \"secret\"\n" &
    "remote = \"secret-origin\"\nrevision = \"" & secretSha & "\"\n"

suite "pre-push protocol v2 policy regressions":
  test "routing config isolation restores exact ambient values after exception":
    let original = snapshotRoutingConfig()
    defer: restoreRoutingConfig(original)
    let scratch = getTempDir() / "policy routing isolation scratch"
    let workspace = getTempDir() / "policy routing isolation workspace"

    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG"]:
      delEnv(name)
    expect ValueError:
      failAfterRoutingIsolation(scratch, workspace)
    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG"]:
      check not existsEnv(name)

    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG"]:
      putEnv(name, "")
    expect ValueError:
      failAfterRoutingIsolation(scratch, workspace)
    for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
                 "REPROBUILD_VCS_PRIVATE_CONFIG"]:
      check existsEnv(name)
      check getEnv(name) == ""

    let hostile = [
      ("REPROBUILD_SYSTEM_CONFIG", "system ; $(not-run) = 'hostile value'"),
      ("REPROBUILD_USER_CONFIG", "user & | < > = \"hostile value\""),
      ("REPROBUILD_VCS_PRIVATE_CONFIG", "vcs * ? [ ] = hostile value")]
    for entry in hostile:
      putEnv(entry[0], entry[1])
    expect ValueError:
      failAfterRoutingIsolation(scratch, workspace)
    for entry in hostile:
      check existsEnv(entry[0])
      check getEnv(entry[0]) == entry[1]

  test "dependency and preserved-hook policy remain ordered before lock write":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDir(fx.scratch)
      let prior = getEnv("REPROBUILD_REPRO")
      putEnv("REPROBUILD_REPRO", fx.reproBin)
      defer:
        if prior.len > 0: putEnv("REPROBUILD_REPRO", prior)
        else: delEnv("REPROBUILD_REPRO")

      discard commit(gitBin, fx.dep, "dep-unpublished")
      let appUnpublished = commit(gitBin, fx.app, "app-outgoing")
      let appRemoteBefore = bareHead(gitBin, fx.appOrigin)

      writeFile(fx.app / "dirty-current.txt", "dirty current\n")
      let currentDirty = run(q(gitBin) & " -C " & q(fx.app) &
        " push origin main")
      check currentDirty.code != 0
      check "dirty" in currentDirty.output
      check bareHead(gitBin, fx.appOrigin) == appRemoteBefore
      check not fileExists(fx.workspace / ".repro" / "manifests" /
        "locks" / "app" / "app" / (appUnpublished & ".toml"))
      removeFile(fx.app / "dirty-current.txt")

      let depFailure = run(q(gitBin) & " -C " & q(fx.app) &
        " push origin main")
      check depFailure.code != 0
      check "dep" in depFailure.output
      check "unpublished" in depFailure.output
      check bareHead(gitBin, fx.appOrigin) == appRemoteBefore
      check not fileExists(fx.workspace / ".repro" / "manifests" /
        "locks" / "app" / "app" / (appUnpublished & ".toml"))

      discard require(q(gitBin) & " -C " & q(fx.dep) &
        " push --no-verify origin main")
      let depPublished = run(q(gitBin) & " -C " & q(fx.dep) &
        " branch -r --contains HEAD")
      if depPublished.code != 0 or "origin/main" notin depPublished.output:
        checkpoint("dependency remote-tracking reachability:\n" &
          depPublished.output)
      check depPublished.code == 0
      check "origin/main" in depPublished.output
      writeFile(fx.dep / "dirty.txt", "dirty\n")
      let dirtyFailure = run(q(gitBin) & " -C " & q(fx.app) &
        " push origin main")
      check dirtyFailure.code != 0
      check "dirty" in dirtyFailure.output
      check bareHead(gitBin, fx.appOrigin) == appRemoteBefore
      check not fileExists(fx.workspace / ".repro" / "manifests" /
        "locks" / "app" / "app" / (appUnpublished & ".toml"))
      removeFile(fx.dep / "dirty.txt")

      let develop = fx.workspace / "develop" / "tool"
      createDir(develop.parentDir())
      discard require(q(gitBin) & " clone " & q(fx.depOrigin) & " " &
        q(develop))
      writeDevelopOverride(fx.workspace, "tool", develop)
      writeFile(develop / "dirty-override.txt", "dirty override\n")
      let overrideFailure = run(q(gitBin) & " -C " & q(fx.app) &
        " push origin main")
      check overrideFailure.code != 0
      check hasFailure(fx.report(), "develop_override_dirty")
      check bareHead(gitBin, fx.appOrigin) == appRemoteBefore
      check not fileExists(fx.workspace / ".repro" / "manifests" /
        "locks" / "app" / "app" / (appUnpublished & ".toml"))
      removeFile(fx.workspace / ".repro" / "develop-overrides.toml")
      removeDir(develop)

      let localHook = fx.app / ".git" / "hooks" /
        "pre-push.repro-local"
      let userLog = fx.scratch / "user-hook.log"
      executable(localHook,
        "#!/usr/bin/env sh\n" &
        "printf 'cap=%s legacy=%s dispatcher=%s\\n' " &
        "\"${" & HookCapabilityEnv & ":-}\" " &
        "\"${" & LegacyHookSentinelEnv & ":-}\" " &
        "\"${" & HookDispatcherProtocolEnv & ":-}\" >> " & q(userLog) & "\n" &
        "cat >/dev/null\nexit 71\n")
      let userFailure = run(q(gitBin) & " -C " & q(fx.app) &
        " push origin main")
      check userFailure.code != 0
      check readFile(userLog).strip() == "cap= legacy= dispatcher="
      check bareHead(gitBin, fx.appOrigin) == appRemoteBefore
      check not fileExists(fx.workspace / ".repro" / "manifests" /
        "locks" / "app" / "app" / (appUnpublished & ".toml"))

      # Let the preserved hook pass. A guessed token has no pending capability
      # to claim, so it is scrubbed and falls through the ordinary gate. Keep
      # the checkout dirty to prove that the guessed value grants no bypass.
      executable(localHook,
        "#!/usr/bin/env sh\n" &
        "printf 'cap=%s legacy=%s dispatcher=%s\\n' " &
        "\"${" & HookCapabilityEnv & ":-}\" " &
        "\"${" & LegacyHookSentinelEnv & ":-}\" " &
        "\"${" & HookDispatcherProtocolEnv & ":-}\" >> " & q(userLog) & "\n" &
        "cat >/dev/null\nexit 0\n")
      let forged = repeat('a', 64)
      writeFile(fx.app / "forged-token-dirty.txt", "dirty\n")
      let forgedPush = run("env " & HookCapabilityEnv & "=" & forged & " " &
        q(gitBin) & " -C " & q(fx.app) & " push origin main")
      check forgedPush.code != 0
      check "dirty" in forgedPush.output
      check "capability refused" notin forgedPush.output
      check bareHead(gitBin, fx.appOrigin) == appRemoteBefore
      removeFile(fx.app / "forged-token-dirty.txt")

      let policyStoreLog = fx.scratch / "policy-store.log"
      let policyStore = fx.scratch / "policy-store.sh"
      writeRecordingStore(policyStore, policyStoreLog)
      let routingEnvironment =
        isolateRoutingConfig(fx.scratch, fx.workspace)
      defer: restoreRoutingConfig(routingEnvironment)
      writeNativeRoutingConfig(fx.workspace,
        "{ visibility = \"team\", " &
        "backend = \"external-cli\", program = \"" &
        policyStore.replace('\\', '/') &
        "\", repos = [\"app\", \"dep\"] }")
      let projectFile = fx.workspace / ".repro" / "manifests" /
        "projects" / "app.toml"
      let ordinaryProject = readFile(projectFile)
      writeFile(projectFile, requiredCertificateProject(ordinaryProject))
      if fileExists(policyStoreLog): removeFile(policyStoreLog)
      let certFailure = run(q(gitBin) & " -C " & q(fx.app) &
        " push origin main")
      check certFailure.code != 0
      check "certificate" in certFailure.output
      check hasFailure(fx.report(), "certificate-coverage")
      check bareHead(gitBin, fx.appOrigin) == appRemoteBefore
      if fileExists(policyStoreLog):
        check not readFile(policyStoreLog).splitLines().anyIt(
          it.startsWith("put "))
      writeFile(projectFile, ordinaryProject)

      let finalPush = run("env " & LegacyHookSentinelEnv & "=1 " & q(gitBin) &
        " -C " & q(fx.app) & " push origin main")
      if finalPush.code != 0: checkpoint(finalPush.output)
      check finalPush.code == 0
      check bareHead(gitBin, fx.appOrigin) == appUnpublished

      # Route both repos to a real team git-checkout backend, write valid
      # records, then add a newer record that pins an absent commit. The real
      # dispatcher must classify this as integrity corruption rather than
      # silently refreshing it, and it must leave the source remote untouched.
      let teamStore = fx.scratch / "integrity-team-locks"
      initGitStore(gitBin, teamStore)
      writeNativeRoutingConfig(fx.workspace,
        "{ visibility = \"team\", " &
        "backend = \"git-checkout\", path = \"" &
        teamStore.replace('\\', '/') & "\", repos = [\"app\", \"dep\"] }")
      let locked = run(q(fx.reproBin) & " workspace lock " &
        "--workspace-root=" & q(fx.workspace))
      if locked.code != 0: checkpoint(locked.output)
      check locked.code == 0
      let bogus = repeat('d', appUnpublished.len)
      let bogusPath = teamStore / "locks" / "app" / "app" /
        (bogus & ".toml")
      createDir(bogusPath.parentDir())
      writeFile(bogusPath,
        "[[repo]]\nname = \"app\"\npath = \"app\"\nrevision = \"" &
        bogus & "\"\n")
      discard require(q(gitBin) & " -C " & q(teamStore) & " add locks")
      discard require(q(gitBin) & " -C " & q(teamStore) &
        " commit -m 'tamper newest lock record'")
      let storeIdentity = ensureGitToolResolvable(tpmPathOnly, getEnv("PATH"))
      let selectedStore = newGitCheckoutLockStore(storeIdentity, teamStore)
      let routedPathStore = newGitCheckoutLockStore(
        storeIdentity, teamStore.replace('\\', '/'))
      let selected = selectedStore.latestLock("app", "app")
      if selected.isNone or selected.get().key.sha != bogus:
        let history = run(q(gitBin) & " -C " & q(teamStore) &
          " log --first-parent --format=%x01 --name-only -- locks/app/app/")
        checkpoint("tampered lock was not selected from newest-first Git " &
          "history:\n" & history.output)
      check selected.isSome
      if selected.isSome:
        check selected.get().key.sha == bogus
      let routedPathSelected = routedPathStore.latestLock("app", "app")
      check routedPathSelected.isSome
      if routedPathSelected.isSome:
        check routedPathSelected.get().key.sha == bogus
      check lockedShaFromStore(selectedStore, "app", "app", "app") == bogus
      let resolvedForIntegrity = resolveProject(projectFile)
      var resolvedApp: ResolvedRepo
      for repo in resolvedForIntegrity.repos:
        if repo.name == "app": resolvedApp = repo
      let directLocked = populateLockedDeps(LockSource(
        kind: lskManifestRepo, workspaceRoot: fx.workspace,
        projectName: "app", repos: @[resolvedApp], store: selectedStore))
      check directLocked.deps.len == 1
      if directLocked.deps.len == 1:
        check directLocked.deps[0].coordinates.revision == bogus
      let directFailures = verifyLockedIntegrityAtCoordinates(
        fx.workspace, directLocked)
      check directFailures.len > 0
      let integrityCommitMarker = fx.scratch / "integrity-commit-marker"
      executable(teamStore / ".git" / "hooks" / "pre-commit",
        "#!/usr/bin/env sh\n: > " & q(integrityCommitMarker) & "\n")
      discard commit(gitBin, fx.app, "integrity-outgoing")
      let selectedAfterSourceCommit = selectedStore.latestLock("app", "app")
      if selectedAfterSourceCommit.isNone or
          selectedAfterSourceCommit.get().key.sha != bogus:
        checkpoint("source commit changed the routed lock selection; newest " &
          "record is " & (if selectedAfterSourceCommit.isSome:
          selectedAfterSourceCommit.get().key.sha else: "<none>"))
      check selectedAfterSourceCommit.isSome
      if selectedAfterSourceCommit.isSome:
        check selectedAfterSourceCommit.get().key.sha == bogus
      let integrityFailure = run(q(gitBin) & " -C " & q(fx.app) &
        " push origin main")
      check integrityFailure.code != 0
      if not hasFailure(fx.report(), "locked-integrity-mismatch"):
        checkpoint("unexpected integrity verdict:\n" &
          integrityFailure.output & "\nreport:\n" &
          pretty(fx.report(), indent = 2))
      check hasFailure(fx.report(), "locked-integrity-mismatch")
      check bareHead(gitBin, fx.appOrigin) == appUnpublished
      check not fileExists(integrityCommitMarker)

  test "an unpublished develop override on the outgoing repo does not refuse":
    ## Bootstrapping. ``repro develop <pkg> --source=<sibling>`` routinely
    ## points an override at a checkout the operator then pushes. Refusing that
    ## push because the override's HEAD is unpublished is circular — the push
    ## under evaluation is what publishes it — so the first push of a new
    ## commit could never be made. The sibling-repo ``unpublished`` stage
    ## already grants the outgoing repo provisional status from the strict
    ## ``outgoing-current`` classification; the override stage now reads the
    ## same proof.
    ##
    ## Falsifiable in both directions: the outgoing repo's own unpublished
    ## HEAD pushes through and lands on the bare remote, while an override on
    ## a DIFFERENT unpublished checkout still refuses and leaves the remote
    ## where it was. Real installed hooks, real local bare remotes, nothing
    ## mocked.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setup(gitBin)
      defer: removeDir(fx.scratch)
      let prior = getEnv("REPROBUILD_REPRO")
      putEnv("REPROBUILD_REPRO", fx.reproBin)
      defer:
        if prior.len > 0: putEnv("REPROBUILD_REPRO", prior)
        else: delEnv("REPROBUILD_REPRO")

      let appRemoteBefore = bareHead(gitBin, fx.appOrigin)
      # The override points at the very repository Git is about to push, and
      # that repository carries a commit no remote has seen yet.
      let appOutgoing = commit(gitBin, fx.app, "app-outgoing")
      check appOutgoing != appRemoteBefore
      writeDevelopOverride(fx.workspace, "app", fx.app)

      let pushed = run(q(gitBin) & " -C " & q(fx.app) & " push origin main")
      checkpoint("outgoing-repo override push:\n" & pushed.output)
      check pushed.code == 0
      check "develop_override_unpublished" notin pushed.output
      check bareHead(gitBin, fx.appOrigin) == appOutgoing

      # The exemption is bound to the outgoing checkout, not to overrides in
      # general: a second override pointing at a DIFFERENT unpublished
      # checkout must still refuse.
      let sideCar = fx.workspace / "develop" / "tool"
      createDir(sideCar.parentDir())
      discard require(q(gitBin) & " clone " & q(fx.depOrigin) & " " &
        q(sideCar))
      discard require(q(gitBin) & " -C " & q(sideCar) &
        " config user.email tester@example.invalid")
      discard require(q(gitBin) & " -C " & q(sideCar) &
        " config user.name 'Policy Tester'")
      discard commit(gitBin, sideCar, "override-local-only")
      writeDevelopOverride(fx.workspace, "tool", sideCar)
      discard commit(gitBin, fx.app, "app-outgoing-2")

      let refused = run(q(gitBin) & " -C " & q(fx.app) & " push origin main")
      checkpoint("foreign override push:\n" & refused.output)
      check refused.code != 0
      check hasFailure(fx.report(), "develop_override_unpublished")
      check bareHead(gitBin, fx.appOrigin) == appOutgoing

  test "public manifest lock cannot publish a private-only reference":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pre-push-private-visibility-", "")
      defer: removeDir(scratch)
      let workspace = scratch / "workspace"
      let appOrigin = scratch / "app.git"
      let depOrigin = scratch / "dep.git"
      let secretOrigin = scratch / "secret.git"
      seed(gitBin, appOrigin, scratch / "app-seed")
      seed(gitBin, depOrigin, scratch / "dep-seed")
      seed(gitBin, secretOrigin, scratch / "secret-seed")
      let appSha = bareHead(gitBin, appOrigin)
      let depSha = bareHead(gitBin, depOrigin)
      let secretSha = bareHead(gitBin, secretOrigin)

      createDir(workspace / ".repro")
      let publicLayer = workspace / ".repro" / "manifests-public"
      let privateLayer = workspace / ".repro" / "manifests-private"
      let publicBare = scratch / "manifests-public.git"
      let privateBare = scratch / "manifests-private.git"
      seedManifestLayer(gitBin, publicLayer, publicBare, [
        ("projects/app.toml", manifestProject("app", @[
          ("app-origin", appOrigin), ("dep-origin", depOrigin)], @[
          "repos/app.toml", "repos/dep.toml"])),
        ("repos/app.toml", manifestRepo("app", "app-origin")),
        ("repos/dep.toml", manifestRepo("dep", "dep-origin")),
      ])
      seedManifestLayer(gitBin, privateLayer, privateBare, [
        ("projects/app.toml", manifestProject("app", @[
          ("secret-origin", secretOrigin)], @["repos/secret.toml"])),
        ("repos/secret.toml", manifestRepo("secret", "secret-origin")),
      ])
      writeFile(workspace / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"app\"\nbranch = \"main\"\n\n" &
        "[[manifest]]\nlocal_path = \"" &
          publicLayer.replace('\\', '/') & "\"\nvisibility = \"public\"\n\n" &
        "[[manifest]]\nlocal_path = \"" &
          privateLayer.replace('\\', '/') & "\"\nvisibility = \"private\"\n")
      for repo in [(appOrigin, workspace / "app"),
                   (depOrigin, workspace / "dep"),
                   (secretOrigin, workspace / "secret")]:
        discard require(q(gitBin) & " clone " & q(repo[0]) & " " & q(repo[1]))
        discard require(q(gitBin) & " -C " & q(repo[1]) &
          " config user.email tester@example.invalid")
        discard require(q(gitBin) & " -C " & q(repo[1]) &
          " config user.name 'Policy Tester'")

      let lockRel = "locks/app/app/" & appSha & ".toml"
      let lockPath = publicLayer / lockRel.replace('/', DirSep)
      createDir(lockPath.parentDir())
      writeFile(lockPath, mixedVisibilityLock(appSha, depSha, secretSha))
      discard require(q(gitBin) & " -C " & q(publicLayer) & " add " &
        q(lockRel))
      discard require(q(gitBin) & " -C " & q(publicLayer) &
        " commit -m 'add invalid public lock'")
      let publicBefore = bareHead(gitBin, publicBare)

      let reproBin = reproBinary()
      let ensured = runShell(shellCommand(@[reproBin, "hooks", "ensure",
        "--vcs", "--workspace-root=" & publicLayer, publicLayer]))
      if ensured.code != 0: checkpoint(ensured.output)
      check ensured.code == 0
      let routingEnvironment = isolateRoutingConfig(scratch, workspace)
      defer: restoreRoutingConfig(routingEnvironment)
      let visibilityStoreLog = scratch / "visibility-store.log"
      let visibilityStore = scratch / "visibility-store.sh"
      writeRecordingStore(visibilityStore, visibilityStoreLog)
      writeNativeRoutingConfig(workspace,
        "{ visibility = \"team\", " &
        "backend = \"external-cli\", program = \"" &
        visibilityStore.replace('\\', '/') &
        "\", repos = [\"app\", \"dep\", \"secret\"] }")
      let prior = getEnv("REPROBUILD_REPRO")
      putEnv("REPROBUILD_REPRO", reproBin)
      defer:
        if prior.len > 0: putEnv("REPROBUILD_REPRO", prior)
        else: delEnv("REPROBUILD_REPRO")
      let pushed = run(q(gitBin) & " -C " & q(publicLayer) &
        " push origin main")
      check pushed.code != 0
      let visibilityReport = parseFile(workspace / ".repro" / "build" / "reports" /
        "check-report.json")
      check hasFailure(visibilityReport, "lock_references_private_repo")
      check "secret" in pushed.output
      check bareHead(gitBin, publicBare) == publicBefore
      if fileExists(visibilityStoreLog):
        check not readFile(visibilityStoreLog).splitLines().anyIt(
          it.startsWith("put "))

  test "shared backend failure refuses while personal warns after marked write":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      for tier in ["team", "personal"]:
        block tierCase:
          let fx = setup(gitBin)
          defer: removeDir(fx.scratch)
          let routingEnvironment =
            isolateRoutingConfig(fx.scratch, fx.workspace)
          defer: restoreRoutingConfig(routingEnvironment)
          let prior = getEnv("REPROBUILD_REPRO")
          putEnv("REPROBUILD_REPRO", fx.reproBin)
          defer:
            if prior.len > 0: putEnv("REPROBUILD_REPRO", prior)
            else: delEnv("REPROBUILD_REPRO")
          let storeLog = fx.scratch / (tier & "-store.log")
          let store = fx.scratch / (tier & "-store.sh")
          writeFailingStore(store, storeLog)
          writeNativeRoutingConfig(fx.workspace,
            "{ visibility = \"" & tier &
            "\", backend = \"external-cli\", program = \"" &
            store.replace('\\', '/') & "\", repos = [\"app\", \"dep\"] }")
          let outgoing = commit(gitBin, fx.app, tier & "-backend-outgoing")
          let before = bareHead(gitBin, fx.appOrigin)
          let pushed = run(q(gitBin) & " -C " & q(fx.app) &
            " push origin main")
          check fileExists(storeLog)
          check readFile(storeLog).splitLines().anyIt(it.startsWith("put "))
          check not dirExists(fx.workspace / ".repro" / "manifests" / "locks")
          if tier == "team":
            if pushed.code == 0:
              checkpoint("unexpected team allow:\n" & pushed.output &
                "\nreport:\n" & pretty(fx.report(), indent = 2))
            check pushed.code != 0
            check hasFailure(fx.report(), "lock-backend-unreachable")
            check bareHead(gitBin, fx.appOrigin) == before
          else:
            if pushed.code != 0: checkpoint(pushed.output)
            if "personal lock backend" notin pushed.output:
              checkpoint("missing personal warning:\n" & pushed.output &
                "\nreport:\n" & pretty(fx.report(), indent = 2))
            check pushed.code == 0
            check "personal lock backend" in pushed.output
            check bareHead(gitBin, fx.appOrigin) == outgoing
