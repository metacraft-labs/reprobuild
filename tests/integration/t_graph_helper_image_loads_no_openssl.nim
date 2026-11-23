## The graph helper image (`reprobuild-helper`) loads no OpenSSL; the engine
## (`reprobuild`) does.
##
## WHY IT MATTERS. The build graph runs the engine's own helper commands
## (`internal compile-provider`, `extract-interface`, `compile-profile`,
## `probe-profile-platforms`, `dev-env-introspect`, `render-dev-env-shell`,
## `cmake-regenerate`) inside monitored actions, so whatever their process
## does at start-up is evidence for the action. The engine is built with
## `-d:ssl`, and Nim's OpenSSL wrapper maps libssl and libcrypto when the
## program starts; on Windows those libraries read entropy while they load,
## which keeps every such action from being cached on its first run. The
## helper image runs the same commands from the same sources WITHOUT
## `-d:ssl`, so no OpenSSL loads there. The draw itself can only be seen on
## Windows (`t_graph_helper_draws_no_entropy_at_start_windows.nim` confirms it
## there); what is checked here, on every host, is its cause.
##
## THE ARMS, each with its control:
##
##   1. THE BUILD TABLES. `apps/entrypoints.txt` builds `reprobuild-helper`
##      with no ssl define and `reprobuild` with one; `repro.nim`'s
##      `reprobuild.apps.reprobuild-helper` edge has no `"ssl"` define and
##      `reprobuild.apps.reprobuild` has. A row or edge that gains `-d:ssl`
##      fails here before anything is built.
##   2. THE BUILT IMAGES (Linux). Under `LD_DEBUG=libs` the dynamic loader
##      reports every library it maps. The helper, running a helper command
##      with the words its edge writes, maps no `libssl` / `libcrypto`; the
##      engine running `--version` does (the control: without it, a loader
##      that reported nothing would pass the helper for the wrong reason).
##      Nim's dynlib wrapper loads its libraries at program start, so a
##      helper rebuilt with `-d:ssl` maps them here whatever command it runs.
##   3. THE IMAGE ANSWERS ONLY ITS HELPERS. Any other command line is
##      refused with exit 2 and a message naming the engine; the helpers are
##      never run by the engine when the helper image is missing, and the
##      helper image never stands in for the engine.
##
## No mocks: the real tables, the real built images in `build/bin`, and the
## real dynamic loader.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core/cli_images
from repro_core/process_streams import drainStream

const OpenSslLibraryNames = ["libssl", "libcrypto"]

proc repoRoot(): string =
  getCurrentDir()

proc entrypointRow(name: string): seq[string] =
  ## The fields of `apps/entrypoints.txt`'s row for ``name`` (name, path,
  ## flags...), or @[] when there is none.
  for raw in lines(repoRoot() / "apps" / "entrypoints.txt"):
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let fields = line.splitWhitespace()
    if fields.len > 0 and fields[0] == name:
      return fields

proc definesSsl(flags: openArray[string]): bool =
  for flag in flags:
    if flag in ["--define:ssl", "-d:ssl", "--d:ssl", "-define:ssl"]:
      return true

proc nimCEdge(actionId: string): string =
  ## The text of the `nim.c(...)` call in `repro.nim` that declares
  ## ``actionId``: from the last `nim.c(` before the id to the id itself.
  let text = readFile(repoRoot() / "repro.nim")
  let idAt = text.find("actionId = \"" & actionId & "\"")
  if idAt < 0:
    return ""
  let start = text.rfind("nim.c(", last = idAt)
  if start < 0:
    return ""
  text[start .. idAt]

proc loadedLibraries(image: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  ## Run ``image args`` with the loader reporting every library it maps
  ## (glibc's `LD_DEBUG=libs`, written to stderr, which is merged here).
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["LD_DEBUG"] = "libs"
  let process = startProcess(image, args = args, env = env,
    options = {poStdErrToStdOut})
  defer: process.close()
  # Read to the end of the pipe, not to its first short read.
  let output = drainStream(process.outputStream)
  (exitCode: process.waitForExit(), output: output)

proc mapsOpenSsl(loaderOutput: string): seq[string] =
  ## The loader lines that say an OpenSSL library was opened.
  for line in loaderOutput.splitLines():
    if "calling init:" in line or "trying file=" in line:
      for name in OpenSslLibraryNames:
        if name in line:
          result.add(line.strip())
          break

suite "the graph helper image loads no OpenSSL":

  test "apps/entrypoints.txt builds the helper without ssl, the engine with it":
    let helper = entrypointRow(ReprobuildHelperName)
    let engine = entrypointRow(ReprobuildEngineName)
    checkpoint("helper row: " & helper.join(" "))
    checkpoint("engine row: " & engine.join(" "))
    require helper.len >= 2
    require engine.len >= 2
    check helper[1] == "apps/reprobuild-helper/reprobuild_helper.nim"
    check not definesSsl(helper[2 .. ^1])
    # Control: the engine keeps TLS (its https cache and deploy paths).
    check definesSsl(engine[2 .. ^1])

  test "repro.nim's helper edge has no ssl define, the engine edge has":
    let helper = nimCEdge("reprobuild.apps.reprobuild-helper")
    let engine = nimCEdge("reprobuild.apps.reprobuild")
    checkpoint(helper)
    require helper.len > 0
    require engine.len > 0
    check "apps/reprobuild-helper/reprobuild_helper.nim" in helper
    check "\"ssl\"" notin helper
    check "\"ssl\"" in engine

  test "the built helper maps no libssl/libcrypto; the engine does":
    when defined(linux):
      let bin = repoRoot() / "build" / "bin"
      let engine = bin / reprobuildEngineExeName()
      let helper = bin / reprobuildHelperExeName()
      for image in [engine, helper]:
        if not fileExists(image):
          checkpoint(image & " does not exist; build both images first " &
            "(`bash scripts/build_apps.sh`)")
          fail()
      if fileExists(engine) and fileExists(helper):
        let tempRoot = createTempDir("repro-helper-openssl", "")
        defer: removeDir(tempRoot)
        # Control first: the engine maps OpenSSL at start-up.
        let control = loadedLibraries(engine, ["--version"])
        check control.exitCode == 0
        # The loader reported anything at all (it ran under LD_DEBUG).
        check "calling init:" in control.output
        let engineSsl = mapsOpenSsl(control.output)
        checkpoint("engine: " & engineSsl.join(" | "))
        check engineSsl.len > 0
        # The helper, running the render edge's helper command over an
        # artifact that does not exist: the role runs and reports it.
        let run = loadedLibraries(helper, ["internal", "render-dev-env-shell",
          "--artifact=" & (tempRoot / "missing.rbde"),
          "--out=" & (tempRoot / "dev-env.env")])
        check "calling init:" in run.output
        check "repro dev-env shell render: error:" in run.output
        let helperSsl = mapsOpenSsl(run.output)
        checkpoint("helper: " & helperSsl.join(" | "))
        check helperSsl.len == 0
    else:
      skip("[platform N/A] LD_DEBUG=libs is glibc's loader trace; the " &
        "build-table arms above run on every host, and the Windows " &
        "confirmation is t_graph_helper_draws_no_entropy_at_start_windows")

  test "the helper image refuses every command that is not a graph helper":
    let helper = repoRoot() / "build" / "bin" / reprobuildHelperExeName()
    if not fileExists(helper):
      checkpoint(helper & " does not exist; build it first " &
        "(`bash scripts/build_apps.sh`)")
      fail()
    else:
      for args in [@["--version"], @["build"], @["internal", "io", "monitor"],
                   @["internal", "direnv-activate"], newSeq[string]()]:
        let (output, code) = execCmdEx(quoteShellCommand(@[helper] & args))
        checkpoint($args & ": " & output)
        check code == 2
        check "runs only the build graph's helper commands" in output
