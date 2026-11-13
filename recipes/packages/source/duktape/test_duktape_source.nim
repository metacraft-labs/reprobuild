## Smoke test for the from-source ``duktapeSource`` recipe.
##
## Supports M9.R.26 Gap 3: polkit's meson build uses duktape as its
## JS engine; the from-source duktape recipe replaces the would-be
## nix-stub.

import std/[unittest]
when defined(reproProviderMode):
  import std/[os, osproc, strutils, tempfiles]
  import repro_core

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://duktape.org/duktape-2.7.0.tar.xz"

const ExpectedHash =
  "90f8d2fa8b5567c6899830ddef2c03f3c27960b11aca222fa17aa7ac613c2890"

suite "duktapeSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    let spec = registeredFetchSpec("duktapeSource")
    check spec.packageName == "duktapeSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("duktapeSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("duktapeSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  when defined(reproProviderMode):
    test "configure promises only files present in a Makefile-variant tarball":
      let root = createTempDir("repro-duktape-configure-", "")
      defer: removeDir(root)
      createDir(root / "src")
      writeFile(root / "repro.nim", "discard\n")
      # Duktape ships Makefile.sharedlibrary, not a bare Makefile.
      writeFile(root / "src/Makefile.sharedlibrary", "all:\n\t@true\n")
      let pkg = PackageDef(packageName: "duktapeSource",
        sourceFile: root / "repro.nim")
      let request = ProviderGraphRequest(kind: prkGraphInvocation,
        providerArtifactId: "test", entryPointId: "duktapeSource.root",
        entryPointBodyHash: "test", reason: girExplicitUserRequest,
        arguments: root, namespace: "project")
      let fragment = buildPackageFragment(pkg, request,
        proc() = buildDuktapeSourcePackage(), includeDefault = false)
      var found = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.commandStatsId != "autotools_package.configure":
          continue
        found = true
        var argv: seq[string] = @[]
        for arg in action.call.arguments:
          if arg.name == "argv":
            argv = arg.encodedValue.split("\x1f")
        let execution = execCmdEx(quoteShellCommand(argv), workingDir = root)
        checkpoint execution.output
        check execution.exitCode == 0
        check action.outputs.len > 0
        for output in action.outputs:
          check fileExists(output)
      check found
