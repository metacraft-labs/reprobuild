import std/[net, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_binary_cache_client
import repro_build_engine
import repro_interface_artifacts
import repro_tool_profiles

proc executable(path, body: string) =
  createDir(parentDir(path))
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc prefix(root, name: string): string =
  root / "catalog" / name / ".repro/output/install"

proc manifest(root, name, deps, script: string; cacheIdentity = ""): string =
  result = "import std/options\nimport repro_project_dsl\n\n" &
    "package " & name & "Source:\n" &
    "  usesImportPath \"stubs\"\n" & deps &
    "  build:\n" &
    "    let materialize = buildAction(id = \"" & name & ".materialize\",\n" &
    "      call = inlineExecCall(@[" & findExe("sh").escape() &
      ", \"-c\", " & script.escape() & "]),\n" &
    "      outputs = @[\".repro/output/install\"], cacheable = false" & cacheIdentity & ")\n" &
    "    defaultTarget(target(\"install\", [materialize]))\n"

proc writeFixture(root, identityLiteral: string) =
  createDir(root / "stubs")
  writeFile(root / "config.nims", "switch(\"path\", thisDir())\n")
  for name in ["closure_a", "closure_b", "closure_c", "closure_native", "closure_runtime"]:
    writeFile(root / "stubs" / (name & ".nim"),
      "import repro_project_dsl\npackage " & name & ":\n  discard\n")
    createDir(root / "catalog" / name)
  let aDeps = "  buildDeps:\n    \"closure_b\"\n" &
    "  nativeBuildDeps:\n    \"closure_native\"\n" &
    "  runtimeDeps:\n    \"closure_runtime\"\n"
  writeFile(root / "catalog/closure_a/repro.nim",
    manifest(root, "closure_a", aDeps, "exit 95",
      ", publishToBinaryCache = true, cacheEntryIdentity = some(" & identityLiteral & ")"))
  for name in ["closure_b", "closure_c", "closure_runtime"]:
    let deps = if name == "closure_b": "  buildDeps:\n    \"closure_c\"\n" else: ""
    let script = quoteShell(findExe("mkdir", followSymlinks = false)) &
      " -p .repro/output/install/usr/bin .repro/output/install/usr/lib; " &
      "printf '#!/bin/sh\\necho closure-ready\\n' > .repro/output/install/usr/bin/" & name &
      "; " & quoteShell(findExe("chmod", followSymlinks = false)) &
      " +x .repro/output/install/usr/bin/" & name
    writeFile(root / "catalog" / name / "repro.nim", manifest(root, name, deps, script))
  # An unavailable native provider must not be resolved for a ready artifact.
  createDir(root / "consumer")
  createDir(root / "consumer/build")
  writeFile(root / "consumer/repro.nim",
    "import repro_project_dsl\npackage consumer:\n" &
    "  usesImportPath \"stubs\"\n" &
    "  buildDeps:\n    \"closure_a\"\n" &
    "  build:\n" &
    "    let consume = buildAction(id = \"consumer.run\",\n" &
    "      call = inlineExecCall(@[" & findExe("sh").escape() & ", \"-c\", " &
      "closure_c > build/result; printf '%s' \"$LD_LIBRARY_PATH\" > build/libs".escape() & "]),\n" &
    "      outputs = @[\"build/result\", \"build/libs\"], cacheable = false,\n" &
    "      toolIdentityRefs = @[\"closure_a\"])\n" &
    "    defaultTarget(target(\"consumer\", [consume]))\n")

proc runCli(binary, root: string; args: seq[string];
            extraEnv: seq[(string, string)] = @[]): tuple[output: string, exitCode: int] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  for (key, value) in [
      (FromSourceRootEnvVar, root / "catalog"),
      ("REPROBUILD_NO_RUNQUOTA", "1"),
      ("REPRO_CACHES_CONFIG", root / "no-global-caches.conf"),
      ("REPRO_BINARY_CACHE_URL", ""),
      ("REPRO_LOCAL_STORE", root / "local-store")]:
    env[key] = value
  for pair in extraEnv: env[pair[0]] = pair[1]
  # Detached tool helpers can retain stdout after the CLI exits. Capture to a
  # regular file so their lifetime does not keep an execCmdEx pipe open.
  let outputPath = root / "cli-output.log"
  let process = startProcess(findExe("sh"), args = @["-c",
    quoteShellCommand(@[binary] & args) & " > " & quoteShell(outputPath) & " 2>&1"],
    workingDir = root / "consumer", env = env, options = {poParentStreams})
  let code = process.waitForExit()
  process.close()
  (readFile(outputPath), code)

proc checkPrepared(root: string) =
  check readFile(root / "consumer/build/result").strip() == "closure-ready"
  check (prefix(root, "closure_c") / "usr/lib") in
    readFile(root / "consumer/build/libs")
  let artifact = readInterfaceArtifact(root /
    "catalog/closure_a/.repro/build/repro/project-interface.rbsz")
  var sawNative, sawRuntime = false
  for useDef in artifact.projectInterface.toolUses:
    if useDef.packageSelector == "closure_native": sawNative = useDef.depKind == "native"
    if useDef.packageSelector == "closure_runtime": sawRuntime = useDef.depKind == "runtime"
  check sawNative
  check sawRuntime
  for name in ["closure_b", "closure_c", "closure_runtime"]:
    check fileExists(prefix(root, name) / "usr/bin" / name)
    check fileExists(root / "catalog" / name / ".repro/build/repro/project-interface.rbsz")
  let identity = readPathOnlyBuildIdentity(root /
    "consumer/.repro/build/repro/from-source-tool-identities.rbtp")
  require identity.profiles.len == 1
  check prefix(root, "closure_c") / "usr/bin" in identity.profiles[0].pathSearchList
  check prefix(root, "closure_native") / "usr/bin" notin identity.profiles[0].pathSearchList

suite "cached source closure preparation through the CLI":
  test "ready and cache-restored prefixes acquire metadata and transitive producers":
    when defined(windows):
      skip()
    else:
      let binary = absolutePath("build/bin/repro")
      let serverBinary = absolutePath("build/bin/repro-binary-cache")
      require fileExists(binary)
      require fileExists(serverBinary)
      let root = createTempDir("closure-cli-", "")
      defer: removeDir(root)
      let local = detectLocalPlatform(root / "platform-store")
      let identityLiteral = "newCacheEntryIdentity(packageName = \"closure_a\", " &
        "packageVersion = \"1\", platform = PlatformTriple(cpu: " & local.cpu.escape() &
        ", os: " & local.os.escape() & ", abi: " & local.abi.escape() &
        "), toolchain = ToolchainIdentity(name: \"fixture\", version: \"1\"), " &
        "providerRevision = \"closure-fixture-v1\")"
      writeFixture(root, identityLiteral)
      let aBinary = prefix(root, "closure_a") / "usr/bin/closure_a"
      executable(aBinary, "#!/bin/sh\nexit 0\n")
      let buildArgs = @["build", "--daemon=off", "--tool-provisioning=from-source",
        "--progress=quiet", "--log=actions", "--measure=none",
        "--action-cache-root=" & root / "action-cache"]
      let ready = runCli(binary, root, buildArgs)
      checkpoint(ready.output)
      require ready.exitCode == 0
      checkPrepared(root)

      let listener = newSocket()
      listener.bindAddr(Port(0), "127.0.0.1")
      let port = listener.getLocalAddr()[1]
      listener.close()
      let server = startProcess(serverBinary,
        args = @["--root=" & root / "cache-server", "--listen=127.0.0.1:" & $port],
        options = {poParentStreams})
      defer:
        server.terminate()
        discard server.waitForExit()
        server.close()
      var listening = false
      for _ in 0 ..< 100:
        let probe = newSocket()
        try:
          probe.connect("127.0.0.1", port)
          listening = true
        except OSError: discard
        finally: probe.close()
        if listening: break
        sleep(50)
      require listening
      let cacheEnv = @[("REPRO_BINARY_CACHE_URL", "http://127.0.0.1:" & $port),
        ("REPRO_BINARY_CACHE_KEY_PATH", root / "producer.key"),
        ("REPRO_BINARY_CACHE_CERT_PATH", root / "producer.cert")]
      let generated = runCli(binary, root, @["cache", "gen-key"], cacheEnv)
      require generated.exitCode == 0
      writeFile(root / "no-global-caches.conf", "[fixture]\nurl = " &
        cacheEnv[0][1].escape() & "\ntrusted-public-keys = " &
        readFile(root / "producer.cert").strip().escape() & "\npriority = 10\n")
      let flags = @["--package-name=closure_a", "--package-version=1",
        "--platform-cpu=" & local.cpu, "--platform-os=" & local.os,
        "--platform-abi=" & local.abi, "--platform-libc=",
        "--toolchain-name=fixture", "--toolchain-version=1",
        "--provider-revision=closure-fixture-v1",
        "--option=" & CachePlatformTagOptionKey & "=" & NativeTriple]
      let derived = runCli(binary, root, @["cache", "derive-key"] & flags, cacheEnv)
      require derived.exitCode == 0
      let key = derived.output.strip()
      let published = runCli(binary, root,
        @["cache", "publish", key, prefix(root, "closure_a")] & flags, cacheEnv)
      checkpoint(published.output)
      require published.exitCode == 0
      for name in ["closure_a", "closure_b", "closure_c", "closure_runtime"]:
        removeDir(root / "catalog" / name / ".repro")
      removeDir(root / "consumer/.repro")
      removeDir(root / "consumer/build")
      createDir(root / "consumer/build")
      let restored = runCli(binary, root, buildArgs, cacheEnv)
      checkpoint(restored.output)
      require restored.exitCode == 0
      check restored.output.contains("from-source cache substitute: restored")
      check readFile(aBinary) == "#!/bin/sh\nexit 0\n"
      checkPrepared(root)
