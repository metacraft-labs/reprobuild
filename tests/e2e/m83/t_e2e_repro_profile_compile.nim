## M83 Phase A end-to-end test: compile each fixture profile with
## `nim c -r`, capture its emitted JSON, and assert the deserialised
## `ProfileIntent` matches a golden in-process construction.
##
## Sub-process compilation is the proxy for the future `repro profile
## build` invocation. Phase A's pure-library scope means the production
## pipeline does NOT invoke this code path yet -- but the gate stays
## green so Phase D's apply integration can rely on it.

import std/[os, osproc, sets, strutils, tables, unittest]

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
