## Production health CLI with real manifest composition and filesystem fixtures.
## Only `gh` is replaced: a deterministic executable models the remote forge API
## so redirects, auth failures and network stalls do not depend on live GitHub
## or credentials. Its argument log verifies that production constructs the API
## identity from composed URLs, strips credentials and deduplicates queries.
## A sleeping executable exercises the actual subprocess timeout/kill boundary.
## Text, verbose, JSON, offline, unavailable tooling and report-only remedies
## are checked alongside case-only spelling and unsupported/local URL controls.
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, times, unittest]
import repro_test_support

# A native fake keeps this network boundary executable on every platform; it
# is the test image itself, copied under the forge client's name. Discovery
# (--list-json) and normal case runs never take this early API-client arm.
if paramCount() > 0 and paramStr(1) == "api":
  let fixture = getEnv("REPRO_HEALTH_FAKE_GH_ROOT")
  let calls = open(fixture / "calls", fmAppend)
  calls.writeLine(commandLineParams().join(" "))
  calls.close()
  let endpoint = if paramCount() >= 4: paramStr(4) else: ""
  if endpoint.startsWith("repos/Org/old"):
    stdout.writeLine("Org/new" & endpoint["repos/Org/old".len .. ^1])
  else:
    case endpoint
    of "repos/Org/case": stdout.writeLine("org/CASE")
    of "repos/Org/moved": stdout.writeLine("OtherOrg/moved")
    of "repos/Org/fail":
      stderr.writeLine("secret-token")
      quit(1)
    of "repos/Org/bad": stdout.writeLine("invalid/output/extra")
    of "repos/Org/hang":
      writeFile(fixture / "hang-pid", $getCurrentProcessId())
      sleep(60000)
    else: quit(9)
  quit(0)

suite "health forge repository identities":
  test "composed forge redirects are visible without changing workspace data":
    let root = createTempDir("health-forge-", "")
    defer: removeDir(root)
    let ws = root / "workspace"
    let tools = root / "tools"
    createDir(ws / "projects")
    createDir(ws / "repos")
    createDir(ws / "url-prefixes")
    createDir(ws / ".repro")
    createDir(tools)
    let binary = requireBinary(getEnv("REPRO_HEALTH_TEST_BINARY",
      currentSourcePath().parentDir.parentDir.parentDir / "build/bin" / addFileExt("repro", ExeExt)),
      "reprobuild.apps.repro")
    let gh = tools / addFileExt("gh", ExeExt)
    let log = root / "calls"
    copyFile(getAppFilename(), gh)
    setFilePermissions(gh, {fpUserRead, fpUserWrite, fpUserExec})
    proc manifest(urls: seq[string]) =
      var project = """schema = "reprobuild.workspace.project.v1"
[project]
name = "fixture"
default_revision = "main"
trunk = "main"
[[remote]]
name = "origin"
fetch = "https://github.com/"
includes = [INCLUDES]
"""
      var includes: seq[string]
      for i, url in urls:
        let name = "repo" & $i
        let prefixName = "prefix" & $i
        var normalized = url.strip(leading = false, trailing = true, chars = {'/'})
        when defined(windows): normalized = normalized.replace('\\', '/')
        let slash = normalized.rfind('/')
        doAssert slash >= 0
        let base = normalized[0 ..< slash]
        let suffix = normalized[slash + 1 .. ^1]
        writeFile(ws / "url-prefixes" / (prefixName & ".toml"),
          "schema = \"reprobuild.workspace.url-prefix.v1\"\n[url-prefix]\nname = " &
          $(%prefixName) & "\nurl = " & $(%base) & "\n")
        includes.add("\"repos/" & name & ".toml\"")
        writeFile(ws / "repos" / (name & ".toml"), """schema = "reprobuild.workspace.repo.v1"
[repo]
name = "NAME"
path = "NAME"
remote = "origin"
url_prefix = "PREFIX"
url_suffix = "SUFFIX"
revision = "main"
""".replace("NAME", name).replace("PREFIX", prefixName).replace("SUFFIX", suffix))
      writeFile(ws / "projects/fixture.toml", project.replace("INCLUDES", includes.join(", ")))
    proc invoke(extra = ""; useTools = true): string =
      let environment = newStringTable(modeCaseInsensitive)
      for key, value in envPairs(): environment[key] = value
      for entry in [
          ("REPRO_HEALTH_FAKE_GH_ROOT", root),
          ("HOME", root / "home"),
          ("XDG_CONFIG_HOME", root / "config"),
          ("XDG_CACHE_HOME", root / "cache"),
          ("XDG_DATA_HOME", root / "data"),
          ("XDG_STATE_HOME", root / "state"),
          ("REPRO_DAEMON_ENDPOINT", root / "absent.sock"),
          ("REPRO_DAEMON_STATE_DIR", root / "daemon"),
          ("REPRO_WORKSPACE_CLONES", root / "clones"),
          ("REPROBUILD_REPRO", binary)]:
        environment[entry[0]] = entry[1]
      environment["PATH"] = if useTools:
          tools & $PathSep & getEnv("PATH") else: root / "empty"
      let process = startProcess(binary,
        args = @["health", "fixture", "--workspace-root=" & ws] & extra.splitWhitespace(),
        env = environment, options = {poStdErrToStdOut})
      defer: process.close()
      result = process.outputStream.readAll()
      discard process.waitForExit()
    proc row(extra = ""; useTools = true; manifestRequired = true): JsonNode =
      let output = invoke("--json " & extra, useTools)
      let start = output.find('{')
      doAssert start >= 0, output
      let report = parseJson(output[start .. ^1])
      if manifestRequired:
        var valid = false
        for c in report["checks"]:
          if c["name"].getStr == "manifest": valid = c["status"].getStr == "ok"
        doAssert valid, "fixture manifest must resolve: " & output
      for c in report["checks"]:
        if c["name"].getStr == "repository-identities": return c
      return newJNull()
    manifest(@["https://github.com/Org/old"])
    let initial = row()
    require initial.kind != JNull
    let help = execCmdEx(quoteShell(binary) & " health --help")
    check help.exitCode == 0
    check "--offline" in help.output
    check "other checks" in help.output
    check initial["status"].getStr == "warn"
    check "Org/old" in initial["detail"].getStr
    check "Org/new" in initial["detail"].getStr
    check initial["fixable"].getBool == false
    check "previously" in initial["remedy"].getStr
    check "URL" in initial["remedy"].getStr
    check "repo0" in initial["remedy"].getStr
    check "repository-identities" in invoke()
    let declaration = readFile(ws / "repos/repo0.toml")
    # The checkout's Git remote is local and HEAD already published. Only the
    # composed manifest identity asks the fake forge; safe --fix can install
    # hooks but cannot accidentally clone/fetch from a live forge.
    proc git(command: string): string =
      let r = execCmdEx("git " & command)
      doAssert r.exitCode == 0, r.output
      r.output.strip()
    let repo = ws / "repo0"
    let origin = root / "origin.git"
    discard git("init --bare -b main " & quoteShell(origin))
    discard git("clone " & quoteShell(origin) & " " & quoteShell(repo))
    discard git("-C " & quoteShell(repo) & " config user.email fixture@example.invalid")
    discard git("-C " & quoteShell(repo) & " config user.name Fixture")
    writeFile(repo / "file", "preserve")
    discard git("-C " & quoteShell(repo) & " add file")
    discard git("-C " & quoteShell(repo) & " commit -m fixture")
    discard git("-C " & quoteShell(repo) & " push -u origin main")
    let head = git("-C " & quoteShell(repo) & " rev-parse HEAD")
    let remote = git("-C " & quoteShell(repo) & " remote get-url origin")
    removeFile(log)
    let fixed = row("--fix")
    check fixed["status"].getStr == "warn"
    check readFile(log).count("api ") == 1
    check readFile(ws / "repos/repo0.toml") == declaration
    check git("-C " & quoteShell(repo) & " rev-parse HEAD") == head
    check git("-C " & quoteShell(repo) & " remote get-url origin") == remote
    removeDir(repo)
    removeFile(log)
    manifest(@["https://user:secret-token@GITHUB.com:443/Org/old.git/",
      "git@github.com:Org/old.git", "ssh://git@github.com:22/Org/case.git",
      "git://github.com/Org/moved", "https://github.com/Org/fail",
      "https://github.com/Org/bad", "https://gitlab.com/Org/old",
      "https://github.com:8443/Org/old", root / "local.git"])
    let mixed = row()
    check mixed["status"].getStr == "warn"
    check "OtherOrg/moved" in mixed["detail"].getStr
    check "unconfirmed" in mixed["detail"].getStr
    check "secret-token" notin $mixed
    let entries = mixed["data"]["repos"]
    check entries[0]["declared"].getStr == "Org/old"
    check entries[1]["canonical"].getStr == "Org/new"
    check entries[2]["outcome"].getStr == "equal"
    check entries[3]["outcome"].getStr == "mismatch"
    check entries[4]["outcome"].getStr == "unconfirmed"
    check "unavailable" in entries[4]["reason"].getStr
    check entries[5]["outcome"].getStr == "unconfirmed"
    check "invalid" in entries[5]["reason"].getStr
    check entries[6]["outcome"].getStr == "unconfirmed"
    check entries[7]["outcome"].getStr == "unconfirmed"
    check entries[8]["outcome"].getStr == "local"
    check mixed["data"]["checked"].getInt == 4
    check mixed["data"]["skipped"].getInt == 5
    let calls = readFile(log)
    check calls.count("api ") == 5
    check calls.count("repos/Org/old --jq") == 1
    check "repos/Org/repo0" notin calls
    check "gitlab" notin calls
    check "secret-token" notin calls
    check mixed["data"]["repos"].len == 9
    let priorCalls = readFile(log)
    let offline = row("--offline")
    check offline["status"].getStr == "warn"
    check "offline" in offline["detail"].getStr
    check readFile(log) == priorCalls
    for n in 0 .. 5:
      check offline["data"]["repos"][n]["outcome"].getStr == "unconfirmed"
    check offline["data"]["checked"].getInt == 0
    let missing = row(useTools = false)
    check missing["status"].getStr == "warn"
    check "gh unavailable" in missing["detail"].getStr
    check readFile(log) == priorCalls
    manifest(@["https://github.com/Org/fail", "https://github.com/Org/case"])
    check row()["data"]["repos"][1]["outcome"].getStr == "equal"
    manifest(@["https://github.com/Org/case"])
    check row()["status"].getStr == "ok"
    manifest(@["github.com:Org/case.git"])
    check row()["status"].getStr == "ok"
    manifest(@[root / "local.git", root / "with@colon:repo.git"])
    let local = row()
    check local["status"].getStr == "ok"
    check local["data"]["repos"][1]["outcome"].getStr == "local"
    manifest(@["https://gitlab.com/Org/old"])
    let beforeUnsupported = readFile(log)
    check row()["status"].getStr == "warn"
    check readFile(log) == beforeUnsupported
    var many: seq[string]
    for n in 0 .. 6: many.add("https://github.com/Org/old" & $n)
    manifest(many)
    check "(+2 more)" in invoke()
    check "Org/new6" notin invoke()
    check "Org/new6" in invoke("--verbose")
    check "Org/new6" in row()["detail"].getStr
    manifest(@["https://github.com/Org/hang", "https://github.com/Org/old"])
    removeFile(log)
    let started = epochTime()
    let timed = row()
    check epochTime() - started < 20
    let hungPid = readFile(root / "hang-pid").strip()
    when defined(posix):
      check execCmdEx("kill -0 " & hungPid).exitCode != 0
    check "timed out" in timed["detail"].getStr
    check "after" in timed["detail"].getStr
    check readFile(log).count("api ") == 1
    check timed["data"]["repos"][1]["outcome"].getStr == "unconfirmed"
    check "after API timeout" in timed["data"]["repos"][1]["reason"].getStr
    removeFile(ws / "projects/fixture.toml")
    let unresolved = row(manifestRequired = false)
    check unresolved["status"].getStr == "warn"
    check "manifest unresolved" in unresolved["detail"].getStr
