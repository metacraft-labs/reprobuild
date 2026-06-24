## M83 Phase A end-to-end test: compile each fixture profile with
## `nim c -r`, capture its emitted JSON, and assert the deserialised
## `ProfileIntent` matches a golden in-process construction.
##
## Sub-process compilation is the proxy for the future `repro profile
## build` invocation. Phase A's pure-library scope means the production
## pipeline does NOT invoke this code path yet -- but the gate stays
## green so Phase D's apply integration can rely on it.

import std/[os, osproc, sets, strutils, tables, unittest]

import repro_elevation
import repro_profile

const
  fixturesDir = currentSourcePath.parentDir.parentDir.parentDir /
    "fixtures" / "m83"
  buildBinDir = currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "build" / "test-bin" / "m83"
  buildCacheDir = currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "build" / "nimcache" / "m83"

proc compileAndRun(fixtureName: string): string =
  ## Compile `<fixturesDir>/<fixtureName>` with `nim c -r`, return its
  ## captured stdout. The compiled binary's only side-effect is the
  ## stdout JSON; we read it via osproc.execProcess so the build
  ## bootstrap text on stderr does not pollute the capture.
  createDir(buildBinDir)
  createDir(buildCacheDir)
  let src = fixturesDir / fixtureName
  let outName = fixtureName.changeFileExt("exe")
  let outPath = buildBinDir / outName
  let cachePath = buildCacheDir / fixtureName.changeFileExt("")
  let compileCmd = "nim c --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(cachePath) & " " &
    "--out:" & quoteShell(outPath) & " " &
    quoteShell(src)
  let compileResult = execCmdEx(compileCmd)
  if compileResult.exitCode != 0:
    raise newException(IOError,
      "fixture compile failed: " & fixtureName & "\n" &
      compileResult.output)
  let runResult = execCmdEx(quoteShell(outPath))
  if runResult.exitCode != 0:
    raise newException(IOError,
      "fixture run failed: " & fixtureName & "\n" & runResult.output)
  result = runResult.output.strip()

suite "M83 Phase A e2e: compile + run user profiles":

  test "home_basic.nim emits expected ProfileIntent JSON":
    let js = compileAndRun("home_basic.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "homeBasic"
    check p.activities.len == 1
    check p.activities[0].name == "default"
    check p.activities[0].body.len == 3
    check p.activities[0].body[0].kind == aekPackageRef
    check p.activities[0].body[0].pkgName == "neovim"
    check p.activities[0].body[1].kind == aekPackageRef
    check p.activities[0].body[1].pkgName == "tmux"
    check p.activities[0].body[2].kind == aekWhenGuard
    check p.activities[0].body[2].predicate.expr == "windows"
    check p.activities[0].body[2].guardedBody.len == 1
    check p.activities[0].body[2].guardedBody[0].pkgName ==
      "windows-terminal"

  test "home_with_module.nim resolves sibling import + template":
    let js = compileAndRun("home_with_module.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "homeWithModule"
    check p.activities.len == 1
    check p.activities[0].name == "development"
    check p.activities[0].body.len == 2
    check p.activities[0].body[0].pkgName == "git"
    check p.activities[0].body[1].pkgName == "gh"
    # The gitDevTooling template contributed both resources.
    check p.resources.len == 2
    var kinds: HashSet[string]
    for r in p.resources:
      kinds.incl r.kind
    check "env.userVariable" in kinds
    check "fs.userFile" in kinds
    for r in p.resources:
      if r.kind == "env.userVariable":
        check r.fields["name"].s == "GIT_PAGER"
        check r.fields["value"].s == "delta"
      else:
        check r.fields["hostFile"].s == "~/.gitconfig"
        check "Test User" in r.fields["content"].s

  test "system_basic.nim builds a system-scope profile":
    let js = compileAndRun("system_basic.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "systemBasic"
    check p.resources.len == 2
    var byKind = initTable[string, ResourceIntent]()
    for r in p.resources:
      byKind[r.kind] = r
    check "windows.capability" in byKind
    check byKind["windows.capability"].fields["installed"].b == true
    check byKind["windows.capability"].fields["name"].s ==
      "OpenSSH.Server~~~~0.0.1.0"
    check "fs.systemFile" in byKind
    check byKind["fs.systemFile"].fields["path"].s ==
      "/etc/hosts.d/local"
    check byKind["fs.systemFile"].fields["content"].s ==
      "127.0.0.1 dev"

  test "system_fssystemfile_sources.nim builds fs.systemFile with all three sources":
    # Windows-System-Resources Phase A e2e: compile + run the fixture
    # that declares one inline-content, one URL-fetch, and one
    # controller-side `sourceLocal` `fs.systemFile`. The e2e gate
    # checks the ProfileIntent JSON — no real fetch, no apply.
    let js = compileAndRun("system_fssystemfile_sources.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "systemFsFileSources"
    check p.resources.len == 3
    var byAddr = initTable[string, ResourceIntent]()
    for r in p.resources:
      byAddr[r.address] = r

    check "hostsInline" in byAddr
    check byAddr["hostsInline"].kind == "fs.systemFile"
    check byAddr["hostsInline"].fields["path"].s == "/etc/hosts.d/local"
    check byAddr["hostsInline"].fields["content"].s == "127.0.0.1 dev"
    check "sourceUrl" notin byAddr["hostsInline"].fields
    check "sha256" notin byAddr["hostsInline"].fields
    check "sourceLocal" notin byAddr["hostsInline"].fields

    check "actionsRunnerZip" in byAddr
    check byAddr["actionsRunnerZip"].kind == "fs.systemFile"
    check byAddr["actionsRunnerZip"].fields["path"].s ==
      "C:\\actions-runner-cache\\actions-runner-win-x64.zip"
    check byAddr["actionsRunnerZip"].fields["sourceUrl"].s.startsWith(
      "https://github.com/actions/runner/releases/download/")
    check byAddr["actionsRunnerZip"].fields["sha256"].s.len == 64
    check "sourceLocal" notin byAddr["actionsRunnerZip"].fields
    # Inline `content` is still emitted by the template (empty), since
    # the template always pushes the `content` key for stable codec
    # shape — the load-bearing fact is that it is empty.
    check byAddr["actionsRunnerZip"].fields["content"].s == ""

    check "myappConfig" in byAddr
    check byAddr["myappConfig"].kind == "fs.systemFile"
    check byAddr["myappConfig"].fields["path"].s ==
      "/etc/myapp/config.toml"
    check byAddr["myappConfig"].fields["sourceLocal"].s ==
      "/home/zah/profiles/myapp.toml"
    check "sourceUrl" notin byAddr["myappConfig"].fields
    check "sha256" notin byAddr["myappConfig"].fields

  test "system_windowsservice_phaseb.nim builds windows.service with Phase B fields":
    # Windows-System-Resources Phase B e2e: compile + run the fixture
    # that declares one legacy three-field windows.service alongside
    # one with all four Phase B optional fields. The e2e gate checks
    # the ProfileIntent JSON — no real apply, no Windows host needed.
    let js = compileAndRun("system_windowsservice_phaseb.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "systemWindowsServicePhaseB"
    check p.resources.len == 2
    var byAddr = initTable[string, ResourceIntent]()
    for r in p.resources:
      byAddr[r.address] = r

    # Legacy three-field shape: back-compat invariant — the four
    # Phase B fields are ABSENT from the intent (the template skips
    # them when they're at default), so a profile that doesn't use
    # them emits byte-identical JSON to today.
    check "legacyService" in byAddr
    check byAddr["legacyService"].kind == "windows.service"
    check byAddr["legacyService"].fields["name"].s == "sshd"
    check byAddr["legacyService"].fields["startType"].s == "Automatic"
    check byAddr["legacyService"].fields["state"].s == "Running"
    check "displayName" notin byAddr["legacyService"].fields
    check "binPath" notin byAddr["legacyService"].fields
    check "recoveryActions" notin byAddr["legacyService"].fields
    check "recoveryResetSeconds" notin byAddr["legacyService"].fields

    # Phase B shape: all four optional fields carry through with the
    # canonical encoding — recovery actions as `action:delayMs` strings
    # in a list, reset as an int, displayName/binPath as strings.
    check "actionsRunnerService" in byAddr
    let svc = byAddr["actionsRunnerService"]
    check svc.kind == "windows.service"
    check svc.fields["name"].s ==
      "actions.runner.metacraft-labs.windows-runner-001"
    check svc.fields["displayName"].s ==
      "GitHub Actions Runner (windows-runner-001)"
    check svc.fields["binPath"].s ==
      "C:\\actions-runner\\bin\\Runner.Listener.exe"
    let actions = svc.fields["recoveryActions"].items
    check actions.len == 3
    check actions[0] == "restart:5000"
    check actions[1] == "restart:10000"
    check actions[2] == "reboot:60000"
    check svc.fields["recoveryResetSeconds"].i == 86400

  test "system_fssystemdirectory.nim builds an fs.systemDirectory + acl":
    let js = compileAndRun("system_fssystemdirectory.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "systemFsDir"
    check p.resources.len == 2
    # Two fs.systemDirectory resources — one bare, one with the inline
    # NTFS ACL builder.
    var byAddr = initTable[string, ResourceIntent]()
    for r in p.resources:
      byAddr[r.address] = r
    check "myappDir" in byAddr
    check byAddr["myappDir"].kind == "fs.systemDirectory"
    check byAddr["myappDir"].fields["path"].s == "/etc/myapp.d"
    check "aclEntries" notin byAddr["myappDir"].fields
    check "aclOwner" notin byAddr["myappDir"].fields

    check "runnerTokenDir" in byAddr
    check byAddr["runnerTokenDir"].kind == "fs.systemDirectory"
    check byAddr["runnerTokenDir"].fields["path"].s ==
      "C:\\actions-runner-tokens"
    check byAddr["runnerTokenDir"].fields["aclOwner"].s == "SYSTEM"
    check byAddr["runnerTokenDir"].fields["aclInheritance"].s ==
      "protected-clear-inherited"
    let aces = byAddr["runnerTokenDir"].fields["aclEntries"].items
    check aces.len == 3
    check aces[0] == "SYSTEM:(F)"
    check aces[1] == "BUILTIN\\Administrators:(F)"
    check aces[2] == "NetworkService:(RX)"

  test "system_fssystemdirectory_acl.nim covers every Phase-D ACL variant":
    # Windows-System-Resources Phase D e2e: compile + run the fixture
    # that declares one fsSystemDirectory per inheritance vocabulary
    # value PLUS the Allow / Deny ACE pivot PLUS an owner-unset
    # stanza. The e2e gate checks the ProfileIntent JSON — no Windows
    # host, no icacls call, no apply.
    let js = compileAndRun("system_fssystemdirectory_acl.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "systemFsDirAcl"
    check p.resources.len == 4
    var byAddr = initTable[string, ResourceIntent]()
    for r in p.resources:
      byAddr[r.address] = r

    # runnerTokenDir: protected-clear-inherited + 3 Allow ACEs +
    # SYSTEM owner. The production actions-runner-tokens shape.
    check "runnerTokenDir" in byAddr
    check byAddr["runnerTokenDir"].kind == "fs.systemDirectory"
    check byAddr["runnerTokenDir"].fields["path"].s ==
      "C:\\actions-runner-tokens"
    check byAddr["runnerTokenDir"].fields["aclOwner"].s == "SYSTEM"
    check byAddr["runnerTokenDir"].fields["aclInheritance"].s ==
      "protected-clear-inherited"
    let runnerAces = byAddr["runnerTokenDir"].fields["aclEntries"].items
    check runnerAces.len == 3
    check runnerAces[0] == "SYSTEM:(F)"
    check runnerAces[1] == "BUILTIN\\Administrators:(F)"
    check runnerAces[2] == "NetworkService:(RX)"

    # runnerCacheDir: disabled-replace + Deny ACE + Administrators
    # owner. Covers the Deny direction's `:(D,W)` marker the driver
    # pivots on at apply time.
    check "runnerCacheDir" in byAddr
    check byAddr["runnerCacheDir"].fields["aclOwner"].s ==
      "BUILTIN\\Administrators"
    check byAddr["runnerCacheDir"].fields["aclInheritance"].s ==
      "disabled-replace"
    let cacheAces = byAddr["runnerCacheDir"].fields["aclEntries"].items
    check cacheAces.len == 3
    check cacheAces[0] == "BUILTIN\\Administrators:(F)"
    check cacheAces[1] == "Users:(RX)"
    check cacheAces[2] == "Guests:(D,W)"

    # reproManagedDir: owner-unset + disabled-convert. The driver
    # skips the takeown / icacls /setowner calls and applies only the
    # entries + inheritance mode.
    check "reproManagedDir" in byAddr
    check byAddr["reproManagedDir"].fields["aclOwner"].s == ""
    check byAddr["reproManagedDir"].fields["aclInheritance"].s ==
      "disabled-convert"
    let managedAces = byAddr["reproManagedDir"].fields["aclEntries"].items
    check managedAces.len == 1
    check managedAces[0] == "NT AUTHORITY\\SYSTEM:(F)"

    # reproDataDir: inheritance = Enabled (the OS default; the driver
    # emits no /inheritance call).
    check "reproDataDir" in byAddr
    check byAddr["reproDataDir"].fields["aclOwner"].s == "SYSTEM"
    check byAddr["reproDataDir"].fields["aclInheritance"].s == "enabled"
    let dataAces = byAddr["reproDataDir"].fields["aclEntries"].items
    check dataAces.len == 1
    check dataAces[0] == "SYSTEM:(M)"

  test "system_windowsscheduledtask.nim builds a windows.scheduledTask per ScheduleKind":
    # Windows-System-Resources Phase C e2e: compile + run the fixture
    # that declares one task per ScheduleKind variant. The e2e gate
    # checks the ProfileIntent JSON — no Windows host, no Task
    # Scheduler call, no apply.
    let js = compileAndRun("system_windowsscheduledtask.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "systemWindowsScheduledTask"
    check p.resources.len == 5
    var byAddr = initTable[string, ResourceIntent]()
    for r in p.resources:
      byAddr[r.address] = r

    # onBoot variant.
    check "onBootTask" in byAddr
    check byAddr["onBootTask"].kind == "windows.scheduledTask"
    check byAddr["onBootTask"].fields["taskName"].s ==
      "\\Reprobuild\\OnBootTask"
    check byAddr["onBootTask"].fields["executable"].s ==
      "C:\\actions-runner\\bin\\Runner.Listener.exe"
    check byAddr["onBootTask"].fields["arguments"].items.len == 1
    check byAddr["onBootTask"].fields["arguments"].items[0] ==
      "--unattended"
    check byAddr["onBootTask"].fields["workingDirectory"].s ==
      "C:\\actions-runner"
    check byAddr["onBootTask"].fields["schedule"].items.len == 1
    check byAddr["onBootTask"].fields["schedule"].items[0] ==
      "onBoot:30"
    check byAddr["onBootTask"].fields["runAsUser"].s == "SYSTEM"
    # Spec §1.3: `runWithHighestPrivileges` is sentinel-aware at the
    # template surface. The fixture does NOT set it explicitly so the
    # field is absent from the intent map; the principal-dependent
    # default (`true` for SYSTEM) applies downstream in the parser and
    # the adapter — exercised in `t_smoke_repro_infra.nim`.
    check "runWithHighestPrivileges" notin byAddr["onBootTask"].fields
    check byAddr["onBootTask"].fields["enabled"].b == true

    # onLogon variant + non-SYSTEM principal. The fixture omits
    # `runWithHighestPrivileges` so the field is absent — the
    # principal-dependent default (`false` for a non-SYSTEM
    # principal) applies downstream.
    check "onLogonTask" in byAddr
    check byAddr["onLogonTask"].fields["schedule"].items[0] ==
      "onLogon:DOMAIN\\runner"
    check byAddr["onLogonTask"].fields["runAsUser"].s ==
      "DOMAIN\\runner"
    check "runWithHighestPrivileges" notin
      byAddr["onLogonTask"].fields

    # once variant.
    check "onceTask" in byAddr
    check byAddr["onceTask"].fields["schedule"].items[0] ==
      "once:2030-01-01T08:00:00Z"

    # daily variant.
    check "dailyTask" in byAddr
    check byAddr["dailyTask"].fields["schedule"].items[0] ==
      "daily:08:30"

    # interval variant + enabled=false.
    check "intervalTask" in byAddr
    check byAddr["intervalTask"].fields["schedule"].items[0] ==
      "interval:15:2030-01-01T00:00:00Z"
    check byAddr["intervalTask"].fields["enabled"].b == false

  test "home_with_config_and_hosts.nim assembles all four sections":
    let js = compileAndRun("home_with_config_and_hosts.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "homeFull"
    check p.activities.len == 2
    check p.configOverrides.len == 3
    # configOverrides preserve declaration order.
    check p.configOverrides[0].pkg == "git"
    check p.configOverrides[0].key == "userName"
    check p.configOverrides[0].value.kind == cvkString
    check p.configOverrides[0].value.s == "Zahary"
    check p.configOverrides[2].pkg == "tmux"
    check p.configOverrides[2].value.kind == cvkBool
    check p.configOverrides[2].value.b == true
    # hosts table.
    check p.hosts.len == 2
    check p.hosts["dev-laptop"] == @["default", "develop_software"]
    check p.hosts["ci"] == @["default"]

  test "home_complex_predicates.nim emits canonical predicate strings":
    let js = compileAndRun("home_complex_predicates.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "homePreds"
    check p.activities.len == 1
    let body = p.activities[0].body
    check body.len == 5  # neovim + 4 guards
    var preds: seq[string]
    for el in body:
      if el.kind == aekWhenGuard:
        preds.add el.predicate.expr
    check preds.len == 4
    # Canonicalised: alphabetical operands.
    check "arm64 and windows" in preds
    check "linux or macos" in preds
    check "not windows" in preds
    check "host == \"dev-laptop\"" in preds

  test "json output is deterministic across two compile+run cycles":
    let js1 = compileAndRun("home_basic.nim")
    let js2 = compileAndRun("home_basic.nim")
    check js1 == js2

  test "Phase E: pokInlineExecCall is in the elevation closed-set":
    # Windows-System-Resources Phase E e2e — the privileged-operation
    # broker's closed-set now includes `pokInlineExecCall` (the
    # elevated `inlineExecCall` build-graph hand-off). This e2e check
    # pins the kind tag + the `requiresElevation` predicate so a
    # downstream profile change that drops the new kind from the set
    # surfaces here (not at apply time on a Windows host).
    #
    # The fixture-driven path (a profile that declares an elevated
    # `inlineExecCall(...)` resource) is Phase F+ territory — Phase E
    # is the engine + broker plumbing only. This test stays in the
    # e2e binary so the gate set is consistent across phases.
    block:
      check $repro_elevation.pokInlineExecCall ==
        "reprobuild.inlineExecCall"
      check repro_elevation.requiresElevation(
        repro_elevation.pokInlineExecCall)
      check repro_elevation.isKnownPrivilegedOperationKind(
        $repro_elevation.pokInlineExecCall)

  test "byte-exact home_basic JSON matches the in-process construction":
    # Sanity check that the JSON the compiled fixture emits matches
    # what an in-process build of the same ProfileIntent would emit.
    var p: ProfileIntent
    p.name = "homeBasic"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekPackageRef, pkgName: "neovim"),
      ActivityElement(kind: aekPackageRef, pkgName: "tmux"),
      ActivityElement(kind: aekWhenGuard,
        predicate: PredicateExpr(expr: "windows"),
        guardedBody: @[ActivityElement(kind: aekPackageRef,
          pkgName: "windows-terminal")])
    ])
    let expected = emitProfileIntentJson(p)
    let actual = compileAndRun("home_basic.nim")
    check actual == expected
