## A consumer's recipe compile reasserts the SDK's bootstrap packages from the
## SDK, never from the consumer (reprobuild-pm issue 2026-11-18-codetracer-
## recipe-extraction-mixes-reprobuild-serialization-with-codetracer-json-
## serialization).
##
## The recipe compile reasserts the SDK's library roots and its bootstrap
## packages (faststreams, stew and the serialization family) after every path
## the recipe's configuration adds, so the SDK compiles against the copies it
## was written for (`protectSdkCompilePaths`). The bootstrap packages were
## resolved with `config.nims`' reprobuild-relative candidate lists, but at the
## CONSUMER's root. For codetracer, which carries older copies of the same
## libraries under `libs/`, each family's marker file chose its copy on its
## own: `json_serialization`, `faststreams` and `stew` came from codetracer,
## while `serialization` came from the SDK because codetracer's copy lacks
## `serialization/case_objects.nim`. The two halves of one library family were
## then reasserted together and the compile failed in `json_serialization`.
##
## No mocks: real directory trees carrying the marker files the resolvers
## probe, and the real command assembly (`providerCompileCommand`, which shares
## `reproPackagePathFlags` and `protectSdkCompilePaths` with the interface
## extraction). The process environment is mutated, so this binary runs on
## its own.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts

const FamilyEnvVars = ["FASTSTREAMS_SRC", "NIM_STEW_SRC",
  "NIM_SERIALIZATION_SRC", "NIM_JSON_SERIALIZATION_SRC",
  "NIM_TOML_SERIALIZATION_SRC"]
  ## The families' explicit overrides. An explicit value outranks every
  ## candidate by design, so the test clears them.

proc touch(path: string) =
  createDir(path.parentDir)
  writeFile(path, "")

proc makeSdk(reprobuildRoot: string) =
  ## A reprobuild checkout as the resolvers see it: the DSL marker and each
  ## bootstrap family in its `libs/<family>/src` layout.
  let libs = reprobuildRoot / "libs"
  touch(libs / "repro_project_dsl" / "src" / "repro_project_dsl.nim")
  touch(libs / "nim-faststreams" / "src" / "faststreams" / "inputs.nim")
  touch(libs / "nim-stew" / "src" / "stew" / "objects.nim")
  touch(libs / "nim-serialization" / "src" / "serialization" /
    "case_objects.nim")
  touch(libs / "nim-json-serialization" / "src" / "json_serialization.nim")
  touch(libs / "nim-toml-serialization" / "src" / "toml_serialization.nim")

proc makeFlatConsumerLibs(consumerRoot: string) =
  ## codetracer's layout: each library's modules at the root of its
  ## `libs/<family>` directory. Its `nim-serialization` predates
  ## `serialization/case_objects.nim`, the marker that family is probed with.
  let libs = consumerRoot / "libs"
  touch(libs / "nim-faststreams" / "faststreams" / "inputs.nim")
  touch(libs / "nim-stew" / "stew" / "objects.nim")
  touch(libs / "nim-serialization" / "serialization" / "errors.nim")
  touch(libs / "nim-json-serialization" / "json_serialization.nim")
  touch(libs / "nim-toml-serialization" / "toml_serialization.nim")

proc makeSrcConsumerLibs(consumerRoot: string) =
  ## The same libraries in the `libs/<family>/src` layout reprobuild uses,
  ## which the first candidate of every list names.
  let libs = consumerRoot / "libs"
  touch(libs / "nim-faststreams" / "src" / "faststreams" / "inputs.nim")
  touch(libs / "nim-stew" / "src" / "stew" / "objects.nim")
  touch(libs / "nim-json-serialization" / "src" / "json_serialization.nim")

proc reassertedRoots(command: openArray[string]): seq[string] =
  ## The roots `protectSdkCompilePaths` reasserts: each one is excluded and
  ## then added again in front of everything else.
  for arg in command:
    if arg.startsWith("--excludePath:"):
      result.add(arg["--excludePath:".len .. ^1])

proc under(path, root: string): bool =
  path == root or path.startsWith(root & DirSep)

proc providerCommand(workspace, consumer: string): seq[string] =
  touch(consumer / "repro.nim")
  providerCompileCommand(consumer / "repro.nim",
    workspace / "out" / "provider", consumer, workspace / "scratch")

template checkSdkOnly(workspace, consumer: string) =
  ## A template, so its `check`s fail the enclosing test.
  let sdk = workspace / "reprobuild" / "libs"
  let roots = reassertedRoots(providerCommand(workspace, consumer))
  checkpoint("reasserted: " & roots.join(", "))
  # Not vacuous: the SDK's copies of these families are reasserted at all.
  check (sdk / "nim-json-serialization" / "src") in roots
  check (sdk / "nim-serialization" / "src") in roots
  check (sdk / "nim-faststreams" / "src") in roots
  check (sdk / "nim-stew" / "src") in roots
  for root in roots:
    check not root.under(consumer)

suite "the SDK's bootstrap packages are reasserted from the SDK":
  var workspace: string
  var savedEnv: seq[(string, string)]

  setup:
    workspace = createTempDir("repro-sdk-packages-", "")
    savedEnv = @[]
    for name in FamilyEnvVars:
      savedEnv.add((name, getEnv(name)))
      delEnv(name)
    savedEnv.add(("REPROBUILD_LIBS_DIR", getEnv("REPROBUILD_LIBS_DIR")))
    makeSdk(workspace / "reprobuild")
    putEnv("REPROBUILD_LIBS_DIR", workspace / "reprobuild" / "libs")

  teardown:
    for (name, value) in savedEnv:
      if value.len > 0: putEnv(name, value) else: delEnv(name)
    removeDir(workspace)

  test "codetracer's flat libs/ copies are not reasserted":
    # The name matters: `config.nims` lists `../codetracer/libs/<family>`
    # among its candidates, and this is the layout that reached it.
    let consumer = workspace / "codetracer"
    makeFlatConsumerLibs(consumer)
    checkSdkOnly(workspace, consumer)

  test "a consumer's libs/<family>/src copies are not reasserted":
    let consumer = workspace / "consumer"
    makeSrcConsumerLibs(consumer)
    checkSdkOnly(workspace, consumer)

  test "a consumer's own copies stay on its search path":
    # The fix narrows which roots are REASSERTED; the consumer's `libs/*/src`
    # are still searched, behind the SDK, as before.
    let consumer = workspace / "consumer"
    makeSrcConsumerLibs(consumer)
    let command = providerCommand(workspace, consumer)
    check ("--path:" & consumer / "libs" / "nim-json-serialization" / "src") in
      command
