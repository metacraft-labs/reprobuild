import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_tool_profiles

proc copyRecipe(name, deps, source, output: string;
                tools: openArray[string]): string =
  var identities: seq[string]
  for tool in tools: identities.add(tool.escape())
  "import repro_project_dsl\n" &
    "import stubs/[cycle_tool, cycle_branch, cycle_leaf, cycle_data]\n" &
    "package " & name & "Source:\n" &
    "  usesImportPath \"stubs\"\n" & deps &
    "  build:\n" &
    "    let materialize = buildAction(id = \"" & name & ".materialize\",\n" &
    "      call = publicCliCall(\"reprobuild.builtin\", \"fs\", \"copyFile\",\n" &
    "        \"reprobuild.builtin.fs.copyFile\", @[\n" &
    "          inputArg(\"source\", " & source.escape() & "),\n" &
    "          outputArg(\"output\", " & output.escape() & ")]),\n" &
    "      inputs = @[" & source.escape() & "], outputs = @[" & output.escape() & "],\n" &
    "      toolIdentityRefs = @[" & identities.join(", ") & "], cacheable = false)\n" &
    "    defaultBuildAction(materialize)\n"

proc createFixture(root: string) =
  createDir(root / "stubs")
  createDir(root / "consumer")
  createDir(root / "bootstrap/bin")
  writeFile(root / "config.nims", "switch(\"path\", thisDir())\n")
  let bootstrap = root / "bootstrap/bin/cycle_tool"
  writeFile(bootstrap, "#!/bin/sh\necho bootstrap-ready\n")
  setFilePermissions(bootstrap, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  let archive = root / "bootstrap.tar"
  let tar = findExe("tar", followSymlinks = false)
  doAssert tar.len > 0, "tar is required for the local bootstrap fixture"
  let packed = execCmdEx(quoteShellCommand(@[tar, "-cf", archive,
    "-C", root / "bootstrap", "bin"]))
  doAssert packed.exitCode == 0, packed.output
  for name in ["cycle_tool", "cycle_branch", "cycle_leaf", "cycle_data"]:
    createDir(root / "catalog" / name)
    writeFile(root / "catalog" / name / "payload", name & "-ready\n")
    var contract = "import repro_project_dsl\npackage " & name & ":\n"
    if name == "cycle_tool":
      contract.add("  provisioning:\n" &
        "    tarball url = " & ("file://" & archive).escape() & ",\n" &
        "      sha256 = " & fileSha256Hex(archive).escape() & ", archiveType = \"tar\",\n" &
        "      stripComponents = 0, executablePath = \"bin/cycle_tool\",\n" &
        "      packageId = \"cycle_tool@1\", cpu = \"any\", os = \"any\"\n")
    else:
      contract.add("  discard\n")
    writeFile(root / "stubs" / (name & ".nim"), contract)
  let nativeBranch = "  nativeBuildDeps:\n    \"cycle_branch\"\n"
  let runtimeData = "  runtimeDeps:\n    \"cycle_data\"\n"
  writeFile(root / "catalog/cycle_tool/repro.nim",
    copyRecipe("cycle_tool", nativeBranch & runtimeData, "payload",
      ".repro/output/install/usr/lib/libcycle_tool.so", ["cycle_branch", "cycle_data"]))
  # The branch queues the runtime data after cycle_leaf. The leaf must prepare
  # that closure itself rather than assume its suspended ancestor has done so.
  writeFile(root / "catalog/cycle_branch/repro.nim",
    copyRecipe("cycle_branch", "  nativeBuildDeps:\n    \"cycle_tool\"\n    \"cycle_leaf\"\n",
      "payload", ".repro/output/install/usr/lib/libcycle_branch.so",
      ["cycle_tool", "cycle_leaf"]))
  writeFile(root / "catalog/cycle_leaf/repro.nim",
    copyRecipe("cycle_leaf", "  nativeBuildDeps:\n    \"cycle_tool\"\n",
      "../cycle_data/.repro/output/install/etc/bundle", ".repro/output/install/usr/lib/libcycle_leaf.so",
      ["cycle_tool"]))
  writeFile(root / "catalog/cycle_data/repro.nim",
    copyRecipe("cycle_data", "", "payload", ".repro/output/install/etc/bundle", []))
  writeFile(root / "consumer/repro.nim",
    copyRecipe("consumer", "  nativeBuildDeps:\n    \"cycle_tool\"\n",
      "../catalog/cycle_leaf/.repro/output/install/usr/lib/libcycle_leaf.so",
      "build/result", ["cycle_tool"]))

suite "nested bootstrap runtime closure":
  test "nested consumer prepares runtime data of an already cycle-broken tool":
    when defined(windows):
      skip()
    else:
      let binary = absolutePath("build/bin/repro")
      require fileExists(binary)
      let root = createTempDir("nested-bootstrap-", "")
      defer: removeDir(root)
      createFixture(root)
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs(): env[key] = value
      for pair in [
          ("REPRO_FROM_SOURCE_ROOT", root / "catalog"),
          ("REPROBUILD_WORK_ROOT", root / "work"),
          ("REPROBUILD_ACTION_CACHE_ROOT", root / "action-cache"),
          ("REPROBUILD_STORE_ROOT", root / "store"),
          ("REPRO_STORE_ROOT", root / "store"),
          ("REPRO_LOCAL_STORE", root / "store"),
          ("REPRO_CACHE_DISABLE", "1")]:
        env[pair[0]] = pair[1]
      let output = root / "cli.log"
      let args = @[binary, "build", "--daemon=off", "--tool-provisioning=from-source",
        "--progress=quiet", "--log=actions", "--write-report"]
      let process = startProcess(findExe("sh"), args = @["-c",
        quoteShellCommand(args) & " > " & quoteShell(output) & " 2>&1"],
        workingDir = root / "consumer", env = env, options = {poParentStreams})
      let code = process.waitForExit()
      process.close()
      let log = readFile(output)
      checkpoint(log)
      require code == 0
      check log.contains("from-source cycle break: routing \"cycle_tool\"")
      check log.contains("from-source auto-recurse: validating \"cycle_data\"")
      check readFile(root / "consumer/build/result") == "cycle_data-ready\n"
      check readFile(root / "catalog/cycle_tool/.repro/output/install/usr/lib/libcycle_tool.so") ==
        "cycle_tool-ready\n"
