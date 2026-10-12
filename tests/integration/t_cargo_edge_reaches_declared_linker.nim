## A cargo edge reaches the C linker and `rustc` its recipe declares.
##
## THE DEFECT. `cargo build` does not link Rust code itself: it runs
## `rustc`, and `rustc` runs a C compiler driver (`cc`) as its linker. A
## typed-tool edge's `PATH` is composed from the edge's own tool plus the
## tools the edge names (`toolIdentityRefs`), and the stdlib `cargo`
## package named nothing. So a recipe that declared `"gcc >=12"` in
## `uses:` got a gcc profile that no edge referenced: `scopedToolArtifact`
## dropped it before resolution, and the cargo edge ran with whatever the
## caller's shell happened to offer. In CI that was nothing, and every
## Rust recorder died with ``error: linker `cc` not found``. Under Nix
## provisioning the same gap also hid `rustc`, which `nixpkgs#cargo` does
## not ship beside `cargo`.
##
## THE CONTRACT. The `cargo` package declares, under `cli:`, the bare-name
## tools it shells out to — `subTools "rustc", "gcc", "clang"`. For every
## cargo edge, each of those the recipe declares in `uses:` is resolved and
## its directory is placed on the edge's `PATH` right after cargo's own.
## A name the recipe does not declare is inert. Sub-tools are NOT the
## edge's complete tool set (a build script may run anything), so they do
## not make the edge's `PATH` hermetic: the host tail stays, as before.
##
## HOW IT IS OBSERVED. A real `repro build` of
## `tests/fixtures/cargo-subtools` (a hello-world crate, path provisioning)
## with a `gcc` placed on `PATH` through a directory of its own, so its
## resolved directory is distinguishable. The test then reads the build's
## own provider snapshot and tool identities and lowers the cargo edge the
## way the engine does (`lowerProviderSnapshot`), asserting on the `PATH`
## the edge was given. The build itself must succeed and the binary run.
##
## Assertions:
##   1. the build's tool identities contain a `gcc` profile (red: the
##      unreferenced `uses:` entry was scoped away);
##   2. the cargo edge's `PATH` begins with cargo's directory followed by
##      the `rustc` and `gcc` profiles' directories (red: gcc absent);
##   3. `PATH` is still declared passthrough — the edge inherits the host
##      tail rather than becoming hermetic;
##   4. the produced binary runs and prints `cargo-subtools-ok`.
##
## No mocks: real repro, real cargo/rustc/gcc from the host. The one
## arrangement is a symlink directory holding `gcc` prepended to `PATH`,
## which changes where gcc is FOUND, not what it is.
##
## Skip rule: POSIX only; skipped when cargo, rustc or gcc is not on PATH.

import std/[json, os, sequtils, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import repro_core
import repro_interface_artifacts
import repro_provider_runtime
import repro_test_support
import repro_tool_profiles

suite "cargo edges reach their declared sub-tools":
  test "a declared gcc and rustc land on the cargo edge's PATH":
    when defined(posix):
      let cargoExe = findExe("cargo")
      let rustcExe = findExe("rustc")
      let gccExe = findExe("gcc")
      if cargoExe.len == 0 or rustcExe.len == 0 or gccExe.len == 0:
        skip("cargo, rustc and gcc must all be on PATH to build the fixture")
      else:
        let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
        let reproBin = requireBinary(reproBinaryPath(repoRoot),
          "reprobuild.apps.repro")
        let scratch = createTempDir("cargo-subtools-", "")
        defer: removeDir(scratch)
        let projectRoot = scratch / "recipe"
        copyDir(repoRoot / "tests/fixtures/cargo-subtools", projectRoot)
        let gccDir = scratch / "gcc-bin"
        createDir(gccDir)
        createSymlink(gccExe, gccDir / "gcc")
        let reportPath = scratch / "report.json"
        let args = @[reproBin, "build", projectRoot,
          "--daemon=off", "--tool-provisioning=path",
          "--work-root=" & (scratch / "work"),
          "--action-cache-root=" & (scratch / "cache"),
          "--write-report=" & reportPath, "--progress=quiet"]
        let oldPath = getEnv("PATH")
        putEnv("PATH", gccDir & $PathSep & oldPath)
        defer: putEnv("PATH", oldPath)
        discard requireSuccess(shellCommand(args), repoRoot)
        require fileExists(reportPath)
        let report = parseFile(reportPath)
        let metadataRoot =
          report["providerSnapshot"].getStr.parentDir.parentDir
        let snapshot = loadProviderGraphSnapshot(
          metadataRoot / "provider-graph")
        let identity = readPathOnlyBuildIdentity(
          metadataRoot / "path-only-tool-identities.rbtp")

        proc profileDir(name: string): string =
          for p in identity.profiles:
            if p.executableName == name or p.packageSelector == name:
              return parentDir(p.resolvedExecutablePath)
          ""

        let gccProfileDir = profileDir("gcc")
        let rustcProfileDir = profileDir("rustc")
        let cargoProfileDir = profileDir("cargo")
        check gccProfileDir.len > 0
        check rustcProfileDir.len > 0
        check cargoProfileDir.len > 0

        let lowered = lowerProviderSnapshot(snapshot, identity, projectRoot,
          "cargo-subtools.build")
        let edges = lowered.actions.filterIt(it.id == "cargo-subtools.build")
        require edges.len == 1
        let pathEntries = edges[0].env.filterIt(it.startsWith("PATH="))
        require pathEntries.len == 1
        let dirs = pathEntries[0]["PATH=".len .. ^1].split(PathSep)
        check dirs.len >= 3
        if dirs.len >= 3:
          check dirs[0] == cargoProfileDir
          # rustc and gcc follow cargo, in the declared sub-tool order,
          # ahead of anything inherited from the host.
          let rustcAt = dirs.find(rustcProfileDir)
          let gccAt = dirs.find(gccProfileDir)
          check rustcAt in 0 .. 2
          check gccAt in 0 .. 2
        check "PATH" in edges[0].envPassthrough

        let produced = projectRoot / "target/debug/cargo-subtools-fixture"
        require fileExists(produced)
        check requireSuccess(shellCommand([produced]),
          projectRoot).strip == "cargo-subtools-ok"
    else:
      skip("POSIX only: the fixture links through a C compiler driver")
