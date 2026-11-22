## `repro tool realize`, and activation parity under a per-tool override.
##
## What is asserted, through the built `repro`:
##
##   * `repro tool realize <pkg>` under `--tool-provisioning=path` plus
##     `--tool-provisioning-for=<pkg>=tarball` exits 0 and prints ONE line,
##     the verified prefix, realized in the shared tool store;
##   * `--json` prints one document: package, version, kind,
##     overriddenBy, prefix, executable, receipt (cacheKey, archiveDigest,
##     closureDigest, source, published) and env;
##   * exit 2 for an unknown package, exit 3 for an override to a mode the
##     package has no arm for, exit 1 for a realization failure (a corrupted
##     archive digest, the override coming from
##     `REPRO_TOOL_PROVISIONING_OVERRIDES`), and nothing on stdout in each;
##   * parity: `repro build`, `repro exec` and `repro shell --print-env=posix`
##     under the same override (the flag for the build, the variable for the
##     activations, which take no flag) resolve the tool to the prefix and
##     cache key `tool realize` reported.
##
## No mocks: a real recipe, a real archive behind a `file://` URL (a local
## fixture is all the mechanism needs: no real upstream is involved), and the
## real CLI with an isolated store, work root and action cache.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_core/process_env
import repro_test_support
import repro_test_support/process_fixtures
import repro_test_support/reasoned_skip
import repro_tool_profiles

proc stub(name, archive, sha256: string): string =
  "import repro_project_dsl\npackage " & name & ":\n" &
    "  provisioning:\n" &
    "    tarball url = " & ("file://" & archive).escape() & ",\n" &
    "      sha256 = " & sha256.escape() & ", archiveType = \"tar\",\n" &
    "      stripComponents = 0, executablePath = \"bin/" & name & "\",\n" &
    "      packageId = \"" & name & "@1.0\", version = \"1.0\",\n" &
    "      cpu = \"any\", os = \"any\"\n"

proc createFixture(root: string) =
  createDir(root / "stubs")
  createDir(root / "consumer")
  writeFile(root / "config.nims", "switch(\"path\", thisDir())\n")
  for name in ["sdkfixture", "badfixture"]:
    let tree = root / ("payload-" & name)
    createDir(tree / "bin")
    let tool = tree / "bin" / name
    writeFile(tool, "#!/bin/sh\necho " & name & " 1.0\n")
    setFilePermissions(tool, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    let archive = root / (name & ".tar")
    let packed = execCmdEx(quoteShellCommand(@[findExe("tar"), "-cf",
      archive, "-C", tree, "bin"]))
    doAssert packed.exitCode == 0, packed.output
    let digest =
      if name == "badfixture": "0".repeat(64) else: fileSha256Hex(archive)
    writeFile(root / "stubs" / (name & ".nim"), stub(name, archive, digest))
  writeFile(root / "consumer/payload", "payload\n")
  writeFile(root / "consumer/repro.nim",
    "import repro_project_dsl\n" &
    "import stubs/[sdkfixture, badfixture]\n" &
    "package consumer:\n" &
    "  usesImportPath \"stubs\"\n" &
    "  defaultToolProvisioning \"path\"\n" &
    "  uses:\n" &
    "    \"sdkfixture\"\n" &
    "    \"badfixture\"\n" &
    "  build:\n" &
    "    let materialize = buildAction(id = \"consumer.materialize\",\n" &
    "      call = publicCliCall(\"reprobuild.builtin\", \"fs\", \"copyFile\",\n" &
    "        \"reprobuild.builtin.fs.copyFile\", @[\n" &
    "          inputArg(\"source\", \"payload\"),\n" &
    "          outputArg(\"output\", \"build/result\")]),\n" &
    "      inputs = @[\"payload\"], outputs = @[\"build/result\"],\n" &
    "      toolIdentityRefs = @[\"sdkfixture\"], cacheable = false)\n" &
    "    defaultBuildAction(materialize)\n")

type CliRun = object
  code: int
  stdout: string
  stderr: string

proc runRepro(root: string; args: seq[string];
              extraEnv: openArray[(string, string)] = []): CliRun =
  let env = inheritedEnvTable()
  for pair in [
      ("REPROBUILD_WORK_ROOT", root / "work"),
      ("REPROBUILD_ACTION_CACHE_ROOT", root / "action-cache"),
      ("REPROBUILD_STORE_ROOT", root / "store"),
      ("REPRO_STORE_ROOT", root / "store"),
      ("REPRO_LOCAL_STORE", root / "store"),
      ("REPRO_CACHE_DISABLE", "1"),
      ("REPROBUILD_USER_CONFIG", root / "user-config.toml")]:
    env[pair[0]] = pair[1]
  env.del("REPRO_TOOL_PROVISIONING")
  env.del("REPRO_TOOL_PROVISIONING_OVERRIDES")
  for pair in extraEnv:
    env[pair[0]] = pair[1]
  let outPath = root / "cli.out"
  let errPath = root / "cli.err"
  let process = startProcess(findExe("sh"), args = @["-c",
    quoteShellCommand(@[reproBinaryPath()] & args) & " > " &
      quoteShell(outPath) & " 2> " & quoteShell(errPath)],
    workingDir = root / "consumer", env = env, options = {poParentStreams})
  result.code = process.waitForExit()
  process.close()
  result.stdout = readFile(outPath)
  result.stderr = readFile(errPath)

suite "repro tool realize":
  when defined(windows):
    test "POSIX fixture":
      skip("POSIX only: the fixture packs its archive with tar and runs " &
        "its tool through sh")
  else:
    let root = createTempDir("repro-tool-realize-", "")
    releaseDirAtProcessExit(root)
    createFixture(root)
    const overrideFlags = @["--tool-provisioning=path",
      "--tool-provisioning-for=sdkfixture=tarball"]

    test "an overridden archive tool is realized and its prefix printed":
      require fileExists(reproBinaryPath())
      let run = runRepro(root, @["tool", "realize", "sdkfixture"] &
        overrideFlags)
      checkpoint run.stderr
      check run.code == 0
      let lines = run.stdout.strip().splitLines()
      check lines.len == 1
      let prefix = lines[0]
      check prefix.startsWith(root / "store" / "tool-store")
      check fileExists(prefix / "bin" / "sdkfixture")
      # A tool realized under an override is logged by name on stderr.
      check ToolFallbackOverride in run.stderr

    test "--json prints the §7 document":
      let run = runRepro(root, @["tool", "realize", "sdkfixture", "--json"] &
        overrideFlags)
      checkpoint run.stderr
      check run.code == 0
      let doc = parseJson(run.stdout)
      check doc["package"].getStr() == "sdkfixture"
      # The declared `1.0`, as the realized-version reader normalizes it.
      check doc["version"].getStr() in ["1.0", "1.0.0"]
      check doc["kind"].getStr() == "tarball"
      check doc["overriddenBy"].getStr() == "flag"
      let prefix = doc["prefix"].getStr()
      check doc["executable"].getStr() == prefix / "bin" / "sdkfixture"
      for key in ["cacheKey", "archiveDigest", "closureDigest", "source",
                  "published"]:
        check doc["receipt"].hasKey(key)
      check doc["receipt"]["cacheKey"].getStr().len > 0
      check doc["receipt"]["archiveDigest"].getStr() ==
        fileSha256Hex(root / "sdkfixture.tar")
      check doc["receipt"]["source"].getStr() in ["local", "substituted",
        "realized"]
      var onPath = false
      for dir in doc["env"]["PATH"]["prepend"]:
        if dir.getStr() == prefix / "bin": onPath = true
      check onPath

    test "exit 2: an unknown package, nothing on stdout":
      let run = runRepro(root, @["tool", "realize", "nosuchpackage"] &
        overrideFlags)
      check run.code == 2
      check run.stdout.len == 0
      check "nosuchpackage" in run.stderr

    test "exit 3: an override to a mode with no arm here, nothing on stdout":
      let run = runRepro(root, @["tool", "realize", "sdkfixture",
        "--tool-provisioning=path", "--tool-provisioning-for=sdkfixture=nix"])
      checkpoint run.stderr
      check run.code == 3
      check run.stdout.len == 0
      check "sdkfixture" in run.stderr
      check "nix" in run.stderr

    test "exit 1: a failed realization prints no prefix":
      let run = runRepro(root, @["tool", "realize", "badfixture",
        "--tool-provisioning=path"],
        [("REPRO_TOOL_PROVISIONING_OVERRIDES", "badfixture=tarball")])
      checkpoint run.stderr
      check run.code == 1
      check run.stdout.len == 0

    test "build, exec and shell resolve the same prefix and cache key":
      let realized = runRepro(root, @["tool", "realize", "sdkfixture",
        "--json"] & overrideFlags)
      require realized.code == 0
      let doc = parseJson(realized.stdout)
      let prefix = doc["prefix"].getStr()
      # repro build, flag form. The build resolves the tools its selected
      # action names (`sdkfixture`); `badfixture` is outside that closure.
      let build = runRepro(root, @["build", "--daemon=off",
        "--progress=quiet"] & overrideFlags)
      checkpoint build.stdout & build.stderr
      check build.code == 0
      var found = false
      for path in walkDirRec(root / "work"):
        if path.endsWith("-tool-identities.inspect.json") and
            "+overrides-" in path:
          let inspection = parseJson(readFile(path))
          for profile in inspection["profiles"]:
            if profile["packageSelector"].getStr() == "sdkfixture":
              check profile["selectedStorePath"].getStr() == prefix
              check profile["lockIdentity"].getStr() ==
                doc["receipt"]["cacheKey"].getStr()
              check profile["kind"].getStr() == "tarball"
              found = true
      check found
      # repro exec, variable form (exec takes no flag).
      let exec = runRepro(root, @["exec", "--", "sh", "-c",
        "command -v sdkfixture"],
        [("REPRO_TOOL_PROVISIONING_OVERRIDES", "sdkfixture=tarball")])
      checkpoint exec.stderr
      check exec.code == 0
      check exec.stdout.strip() == prefix / "bin" / "sdkfixture"
      # repro shell --print-env=posix: the same PATH entry. (The `json` form
      # prints the dev-env artifact's inspection, which carries no tool ops
      # in any mode, so it cannot show a tool's PATH entry.)
      let shell = runRepro(root, @["shell", "--print-env=posix"],
        [("REPRO_TOOL_PROVISIONING_OVERRIDES", "sdkfixture=tarball")])
      checkpoint shell.stderr
      check shell.code == 0
      check (prefix / "bin") in shell.stdout
