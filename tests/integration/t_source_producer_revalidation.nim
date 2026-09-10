import std/[os, osproc, strtabs, strutils, unittest]
import source_producer_fixture

proc runConsumer(binary, root, phase: string): tuple[output: string, code: int] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  for (key, value) in sourceFixtureEnv(root):
    env[key] = value
  let outputPath = root / (phase & ".log")
  let args = @[binary, "build", "--daemon=off",
    "--tool-provisioning=from-source", "--progress=quiet", "--log=actions"]
  let process = startProcess(findExe("sh"), args = @["-c",
    quoteShellCommand(args) & " > " & quoteShell(outputPath) & " 2>&1"],
    workingDir = root / "consumer", env = env, options = {poParentStreams})
  let code = process.waitForExit()
  process.close()
  (readFile(outputPath), code)

suite "local source producer revalidation":
  test "consumer tracks recipe imports, action inputs and entry edits":
    when defined(windows):
      skip()
    else:
      let binary = absolutePath("build/bin/repro")
      require fileExists(binary)
      let root = createSourceFixture()
      defer: removeDir(root)
      let producer = root / "catalog/probe"
      let output = root / "consumer/build/result.txt"

      template buildAndCheck(phase, expected: string) =
        block:
          let built = runConsumer(binary, root, phase)
          checkpoint(built.output)
          require built.code == 0
          check readFile(output) == expected

      buildAndCheck("initial", "implementation-one\n")
      let warm = runConsumer(binary, root, "warm")
      checkpoint(warm.output)
      require warm.code == 0
      check readFile(output) == "implementation-one\n"
      check warm.output.contains(
        "action: probe.materialize status=asUpToDate launched=false cache=cdHit")

      writeFile(producer / "recipe_value.nim", "const inputName* = \"two.txt\"\n")
      buildAndCheck("import-changed", "implementation-two\n")
      writeFile(producer / "two.txt", "implementation-three\n")
      buildAndCheck("input-changed", "implementation-three\n")
      writeFile(producer / "repro.nim",
        producerRecipe.replace("fs.copyFile(source = inputName",
          "fs.writeText(text = \"implementation-four\\n\""))
      buildAndCheck("entry-changed", "implementation-four\n")

      # A retained prefix must not hide a failing current producer.
      writeFile(producer / "repro.nim",
        producerRecipe.replace("source = inputName", "source = \"missing.txt\""))
      let failed = runConsumer(binary, root, "producer-failed")
      checkpoint(failed.output)
      check failed.code != 0

  test "existing artifact bootstraps an active producer without skipping it":
    when defined(windows):
      skip()
    else:
      let binary = absolutePath("build/bin/repro")
      require fileExists(binary)
      let root = createSourceFixture()
      defer: removeDir(root)
      let producer = root / "catalog/probe"
      let artifact = producer / ".repro/output/install/usr/lib/libprobe.so"
      createDir(parentDir(artifact))
      writeFile(artifact, "bootstrap-seed\n")
      writeFile(producer / "repro.nim", """
import repro_project_dsl

package probeSource:
  usesImportPath "stubs"
  buildDeps:
    "probe"
  build:
    let materialize = buildAction(id = "probe.materialize",
      call = publicCliCall("reprobuild.builtin", "fs", "copyFile",
        "reprobuild.builtin.fs.copyFile", @[
          inputArg("source", "two.txt"),
          outputArg("output", ".repro/output/install/usr/lib/libprobe.so")]),
      inputs = @["two.txt"],
      outputs = @[".repro/output/install/usr/lib/libprobe.so"],
      toolIdentityRefs = @["probe"])
    defaultBuildAction(materialize)
""")
      let built = runConsumer(binary, root, "bootstrap-seed")
      checkpoint(built.output)
      require built.code == 0
      check readFile(artifact) == "implementation-two\n"
      check readFile(root / "consumer/build/result.txt") == "implementation-two\n"
