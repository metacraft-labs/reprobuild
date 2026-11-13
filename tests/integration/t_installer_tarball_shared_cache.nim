## Installation metadata uses the real signed binary-cache transport, rather
## than a second home-only store. A local server, real tar archive and two
## independent stores prove publication and substitution after upstream goes
## away. No mocks; the server is the normal app built by the suite app edges.
import std/[json, net, os, osproc, tempfiles, unittest]
import repro_interface_artifacts
import repro_peer_cache/auth
import repro_tool_profiles
from repro_tool_profiles/archive_steps import tarballAppTrust
from repro_home_resources/drivers/app_bundle import atrSkipNotarization

proc cleanup(root: string) =
  for path in walkDirRec(root):
    try: setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
  removeDir(root)

suite "installation-class tarballs use the shared binary cache":
  test "nested installation owns its helper receipt as an action input":
    let root = createTempDir("installer-helper-edge-", "")
    defer: cleanup(root)
    var arm = InterfaceTarballProvisioning(url: "https://example.invalid/tool",
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      archiveType: "raw", executablePath: "tool", cpu: "any", os: "any")
    arm.detail.nested7z = true
    let useDef = InterfaceToolUse(rawConstraint: "nested-helper",
      packageSelector: "nested-helper", executableName: "tool",
      tarballProvisioning: @[arm])
    # Graph construction does no fetch. This asserts that an installation
    # requirement has the same dependency and invalidation boundary as an
    # archive-format extractor, rather than discovering a tool during staging.
    let edges = tarballProvisioningEdges(useDef, root / "store")
    require edges.actions.len >= 2
    let action = edges.actions[^1]
    let spec = parseJson(action.builtinText)
    require spec["extractors"].len == 1
    check spec["extractors"][0]["role"].getStr() == ExtractorRoleSevenZip
    let helper = edges.actions[^2]
    check helper.id in action.deps
    check helper.outputs[0] in action.inputs
    check spec["extractors"][0]["receipt"].getStr() == helper.outputs[0]

  test "a cold second store substitutes the installed tree without upstream":
    let root = createTempDir("installer-cache-", "")
    defer: cleanup(root)
    let variables = ["REPRO_CACHE_DISABLE", "REPRO_CACHES_CONFIG",
      "REPRO_BINARY_CACHE_URL", "REPRO_BINARY_CACHE_KEY_PATH",
      "REPRO_BINARY_CACHE_CERT_PATH"]
    var previous: seq[tuple[name, value: string; present: bool]]
    for name in variables:
      previous.add((name, getEnv(name), existsEnv(name)))
    defer:
      for old in previous:
        if old.present: putEnv(old.name, old.value)
        else: delEnv(old.name)
    delEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHES_CONFIG", root / "empty-caches.conf")
    let cert = root / "producer.cert"
    let key = root / "producer.key"
    discard loadOrGenerateKeypair(cert, key)
    putEnv("REPRO_BINARY_CACHE_KEY_PATH", key)
    putEnv("REPRO_BINARY_CACHE_CERT_PATH", cert)
    let listener = newSocket()
    listener.bindAddr(Port(0), "127.0.0.1")
    let port = listener.getLocalAddr()[1]
    listener.close()
    let serverBinary = absolutePath("build/bin" / addFileExt("repro-binary-cache", ExeExt))
    require fileExists(serverBinary)
    let server = startProcess(serverBinary,
      args = @["--root=" & root / "cache", "--listen=127.0.0.1:" & $port],
      options = {poParentStreams})
    defer:
      server.terminate()
      discard server.waitForExit()
      server.close()
    var listening = false
    while not listening and running(server):
      let probe = newSocket()
      try:
        probe.connect("127.0.0.1", port)
        listening = true
      except OSError: discard
      finally: probe.close()
      if listening: break
      sleep(50)
    require listening
    putEnv("REPRO_BINARY_CACHE_URL", "http://127.0.0.1:" & $port)
    createDir(root / "source" / "payload")
    let script = root / "source" / "payload" / "tool"
    writeFile(script, "#!/bin/sh\necho installer-cache\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
    let archive = root / "fixture.tar.gz"
    let tar = findExe("tar")
    require tar.len > 0
    let packed = execCmdEx(quoteShell(tar) & " -czf " & quoteShell(archive) &
      " -C " & quoteShell(root / "source") & " payload")
    require packed.exitCode == 0
    var arm = InterfaceTarballProvisioning(url: "file://" & archive,
      sha256: fileSha256Hex(archive), archiveType: "tar.gz",
      executablePath: "tool", executableAlias: "cached-alias",
      packageId: "installer-cache@1", cpu: "any", os: "any")
    arm.detail.extractPath = "payload"
    let useDef = InterfaceToolUse(rawConstraint: "installer-cache",
      packageSelector: "installer-cache", executableName: "tool",
      tarballProvisioning: @[arm])
    # Relaxed application trust is a local caller policy, never permission
    # to publish an artifact under the normal strict cache identity. Exercise
    # the same publication boundary here with real credentials and transport.
    let previousTrust = tarballAppTrust
    defer: tarballAppTrust = previousTrust
    tarballAppTrust = {atrSkipNotarization}
    let relaxed = resolveTarballTool(useDef, root / "relaxed-store")
    check fileExists(relaxed.selectedStorePath / "tool")
    var manifests = 0
    for path in walkFiles(root / "cache" / "manifests" / "*" / "*.manifest"):
      inc manifests
    check manifests == 0
    tarballAppTrust = {}
    let first = resolveTarballTool(useDef, root / "first-store")
    check readFile(first.selectedStorePath / "cached-alias") == readFile(script)
    for path in walkFiles(root / "cache" / "manifests" / "*" / "*.manifest"):
      inc manifests
    check manifests > 0
    # A successful cold resolve after deleting the archive is the decisive
    # assertion; the separate destination cannot reuse the first prefix.
    removeFile(archive)
    let restored = resolveTarballTool(useDef, root / "second-store")
    check restored.selectedStorePath != first.selectedStorePath
    check readFile(restored.selectedStorePath / "tool") == readFile(script)
    check readFile(restored.selectedStorePath / "cached-alias") == readFile(script)
    check not dirExists(restored.selectedStorePath / "payload")
