## A cargo edge owns its target directory, whatever the host sets.
##
## THE DEFECT (reprobuild-pm issue 2026-11-10-cargo-build-edge-assumes-target-
## sits-at-the-action-working-directory). The `cargo build` edge assumed
## cargo's output sits at `target/` under the action's working directory.
##
##   1. With `CARGO_TARGET_DIR` exported (the CI runners on high-mem-server
##      export it per runner), cargo wrote elsewhere and a cache miss failed:
##      "exited 0 but did not produce its declared output".
##   2. For a crate below the working directory (`--manifest-path
##      rust/Cargo.toml` from the recipe root) the depfile globs
##      `target/{debug,release}/deps/*.d` matched nothing, so the edge read no
##      evidence and reported up-to-date after a real source change, leaving
##      a stale binary.
##
## THE CONTRACT. The edge passes an explicit `--target-dir` (cargo ranks it
## above `CARGO_TARGET_DIR`) and reads the depfiles under that directory.
##
## HOW IT IS OBSERVED. A real `repro build` of `tests/fixtures/cargo-target-dir`
## (a hello-world crate under `rust/`, path provisioning) with
## `CARGO_TARGET_DIR` and `CARGO_BUILD_TARGET_DIR` exported to a directory
## outside the recipe. The fixture does not declare the Rust sources as inputs,
## so only the edge's own dependency evidence can notice an edit:
##   1. the build succeeds and the declared output is under `rust/target`, not
##      under the exported directory;
##   2. after the source is edited, a second `repro build` rebuilds, and the
##      binary prints the new text (red before the fix: up-to-date, old text);
##   3. a third `repro build` with nothing edited leaves the binary untouched.
##
## No mocks: real repro, real cargo/rustc/gcc from the host.
##
## Skip rule: POSIX only; skipped when cargo, rustc or gcc is not on PATH.

import std/[os, strutils, tempfiles, times, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

suite "cargo edges own their target directory":
  test "an exported CARGO_TARGET_DIR does not move the output, and a source edit rebuilds":
    when defined(posix):
      if findExe("cargo").len == 0 or findExe("rustc").len == 0 or
          findExe("gcc").len == 0:
        skip("cargo, rustc and gcc must all be on PATH to build the fixture")
      else:
        let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
        let reproBin = requireBinary(reproBinaryPath(repoRoot),
          "reprobuild.apps.repro")
        let scratch = createTempDir("cargo-target-dir-", "")
        defer: removeDir(scratch)
        let projectRoot = scratch / "recipe"
        copyDir(repoRoot / "tests/fixtures/cargo-target-dir", projectRoot)
        let ambient = scratch / "ambient-target"
        let source = projectRoot / "rust/src/main.rs"
        let produced =
          projectRoot / "rust/target/debug/cargo-target-dir-fixture"

        proc build() =
          let args = @[reproBin, "build", projectRoot,
            "--daemon=off", "--tool-provisioning=path",
            "--work-root=" & (scratch / "work"),
            "--action-cache-root=" & (scratch / "cache"),
            "--progress=quiet"]
          discard requireSuccess(shellCommand(args), repoRoot)

        proc restore(name: string; was: (bool, string)) =
          if was[0]: putEnv(name, was[1]) else: delEnv(name)
        let oldTarget = (existsEnv("CARGO_TARGET_DIR"),
          getEnv("CARGO_TARGET_DIR"))
        let oldBuildTarget = (existsEnv("CARGO_BUILD_TARGET_DIR"),
          getEnv("CARGO_BUILD_TARGET_DIR"))
        putEnv("CARGO_TARGET_DIR", ambient)
        putEnv("CARGO_BUILD_TARGET_DIR", ambient)
        defer:
          restore("CARGO_TARGET_DIR", oldTarget)
          restore("CARGO_BUILD_TARGET_DIR", oldBuildTarget)

        build()
        require fileExists(produced)
        check not dirExists(ambient)
        check requireSuccess(shellCommand([produced]),
          projectRoot).strip == "cargo-target-dir-v1"

        # An unchanged tree must not rebuild.
        let builtAt = getLastModificationTime(produced)
        build()
        check getLastModificationTime(produced) == builtAt

        # A real source edit, with the sources undeclared, is seen through
        # the depfile alone.
        writeFile(source, readFile(source).replace("-v1", "-v2"))
        build()
        check requireSuccess(shellCommand([produced]),
          projectRoot).strip == "cargo-target-dir-v2"
    else:
      skip("POSIX only: the fixture links through a C compiler driver")

  test "a cargo.test edge for a crate below the root rebuilds after a source edit":
    # cargo links no test executable into the profile directory, so the only
    # evidence of this edge is rustc's per-crate deps/*.d, whose sources are
    # relative to the crate's directory (`src/lib.rs`, not `rust/src/lib.rs`).
    # The edge therefore runs in `rust/`; run in the recipe root it resolved
    # them to nothing and reported up-to-date after the edit.
    when defined(posix):
      if findExe("cargo").len == 0 or findExe("rustc").len == 0 or
          findExe("gcc").len == 0:
        skip("cargo, rustc and gcc must all be on PATH to build the fixture")
      else:
        let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
        let reproBin = requireBinary(reproBinaryPath(repoRoot),
          "reprobuild.apps.repro")
        let scratch = createTempDir("cargo-test-crate-dir-", "")
        defer: removeDir(scratch)
        let projectRoot = scratch / "recipe"
        copyDir(repoRoot / "tests/fixtures/cargo-test-crate-dir", projectRoot)
        let source = projectRoot / "rust/src/lib.rs"
        let depsDir = projectRoot / "rust/target/debug/deps"

        proc build() =
          let args = @[reproBin, "build", projectRoot,
            "--daemon=off", "--tool-provisioning=path",
            "--work-root=" & (scratch / "work"),
            "--action-cache-root=" & (scratch / "cache"),
            "--progress=quiet"]
          discard requireSuccess(shellCommand(args), repoRoot)

        proc newestArtefact(): Time =
          for kind, path in walkDir(depsDir):
            if kind == pcFile:
              result = max(result, getLastModificationTime(path))

        build()
        let builtAt = newestArtefact()
        require builtAt != Time()

        build()
        check newestArtefact() == builtAt

        writeFile(source, readFile(source).replace("        assert_eq!(super::answer(), 1);",
          "        assert_eq!(super::answer(), 1); // edited"))
        build()
        check newestArtefact() > builtAt
    else:
      skip("POSIX only: the fixture links through a C compiler driver")
