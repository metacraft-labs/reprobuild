## A library that two top-level binaries enable different features of is
## never served from one binary's build to the other's.
##
## The fixture (`tests/fixtures/cargo-two-binaries-features`) is a real cargo
## workspace of three path crates, built offline by the typed `cargo` tool:
## `featlib` with features `alpha` and `beta`, and `app-alpha` / `app-beta`,
## which enable one each. Its build file builds, for the top-level binary it
## selects (`selected-app.txt`), the library alone with that binary's feature
## (`cargo build --package featlib --features <feature>`, edge `featlib`,
## declared output `target/featlib/debug/libfeatlib.rlib`) and the binary
## alone (edge `app`), plus the whole workspace in one invocation (edge
## `workspace`).
##
## One checkout is built four times: for `app-alpha`, then `app-beta`, then
## `app-alpha` and `app-beta` again. Between builds only the fixture's
## `selected-app.txt` changes (the build file reads the selection from it),
## so the `featlib` edge keeps its id, its target directory and its declared
## output, and its command line differs in the `--features` value alone. That is the case in which a cache key
## that ignored the feature set would serve the first binary's library to
## the second.
##
## ASSERTIONS. Every build's rlib carries the selected feature's symbol and
## not the other's, and the selected binary prints it; in every build that
## switches the feature, the engine executed the `featlib` edge (launched,
## not a hit), so the evidence shows what ran.
##
## VACUITY GUARD: the two library builds differ in compiled feature set,
## asserted on the rlibs' symbols (`featlib::alpha_marker` only in the one,
## `featlib::beta_marker` only in the other), and the two rlibs' bytes
## differ. The symbol is the mangled codegen name: rustc also records the
## NAME of an item a disabled feature removes in the crate metadata (for its
## diagnostics), so a plain search for `beta_marker` finds it in an `alpha`
## rlib too.
##
## NEGATIVE CONTROL: the whole-workspace edge, whose command line does not
## change between the builds, is executed once and served from its own
## record after that, so "the library edge executed again" is about its
## features, not about a cache that never hits.
##
## FALSIFYING MUTATION (run by hand): keying the cargo edge without its
## feature set turns this test red, the second build serving the `alpha`
## rlib for `app-beta`. The feature set reaches the key twice, so the
## mutation removes both: the typed call's `features` argument from the
## payload the lowering keys the action by, and `--features <value>` from
## the argv the engine keys it by (`keyedOnArgv`). Removing only the second
## leaves the test green, because the first still separates the keys.
##
## No mocks: the built `repro`, the dev shell's cargo, rustc and gcc (path
## provisioning), a real Git checkout in a fresh temporary directory, and the
## engine's own build report.
##
## Skip rule: POSIX only; skipped, loudly, when cargo, rustc or gcc is not on
## PATH.

import std/[os, osproc, strutils, unittest]

import repro_test_support/reasoned_skip
import library_cache_sharing_fixture

const
  FixtureDir = ReprobuildRoot / "tests" / "fixtures" /
    "cargo-two-binaries-features"
  LibraryEdge = "featlib"
  WorkspaceEdge = "workspace"
  Rlib = "target/featlib/debug/libfeatlib.rlib"

proc featureSymbols(rlib: string): tuple[alpha, beta: bool] =
  ## Whether the rlib's object code defines each feature's function. Rust's
  ## legacy mangling spells `featlib::alpha_marker` as
  ## `_ZN7featlib12alpha_marker17h<hash>E`; the length-prefixed segments are
  ## what make the match a symbol and not the metadata's list of
  ## configured-out names.
  let bytes = readFile(rlib)
  (alpha: "7featlib12alpha_marker" in bytes,
   beta: "7featlib11beta_marker" in bytes)

proc selectApp(project, feature: string) =
  ## Select the top-level binary the next build is for. The fixture's build
  ## file reads it from this file, so the build file itself, whose text
  ## keys every action it declares, stays the same.
  writeFile(project / "selected-app.txt", feature & "\n")

suite "two top-level binaries enabling different features of one library":
  test "building the second binary never serves the first one's library":
    when not defined(posix):
      skip("POSIX only: the fixtures are built with POSIX tools")
    else:
      if findExe("cargo").len == 0 or findExe("rustc").len == 0 or
          findExe("gcc").len == 0:
        skip("cargo, rustc and gcc must be on PATH")
      else:
        var host = newSharedHost("cargo-two-binaries-")
        defer: host.cleanup()
        let project = host.scratch / "checkout" / "ws"
        copyCheckout(FixtureDir, project)
        var rlibs: seq[string] = @[]
        var runs: seq[BuildRun] = @[]
        for (step, feature) in [(1, "alpha"), (2, "beta"), (3, "alpha"),
                                (4, "beta")]:
          if step > 1:
            selectApp(project, feature)
          let run = host.build(project, portable = false, provisioning = "path")
          checkpoint("build " & $step & " (" & feature & "):\n" &
            run.allEngineReasons() & run.output)
          require run.code == 0
          require run.hasEdge(LibraryEdge)
          runs.add(run)
          let symbols = featureSymbols(project / Rlib)
          # The library output is the selected binary's, whatever was built
          # before it in this checkout.
          check symbols.alpha == (feature == "alpha")
          check symbols.beta == (feature == "beta")
          let binary = project / "target/app/debug/app-" & feature
          let printed = execCmdEx(quoteShell(binary)).output
          check ("featlib=" & feature & " ") in printed
          if step > 1:
            # The feature changed, so the library edge ran again.
            check run.launched(LibraryEdge)
            check run.cacheDecision(LibraryEdge) != "cdHit"
          rlibs.add(readFile(project / Rlib))

        # Vacuity guard: the two library builds differ in feature set (the
        # symbols, checked per build above) and in bytes. Compared as a
        # boolean, so a failure does not print two rlibs.
        let librariesDiffer = rlibs[0] != rlibs[1]
        check librariesDiffer

        # Negative control: an edge whose command line did not change is
        # served from its own record after its first build.
        check runs[0].launched(WorkspaceEdge)
        for run in runs[1 .. ^1]:
          require run.hasEdge(WorkspaceEdge)
          check not run.launched(WorkspaceEdge)
          check run.cacheDecision(WorkspaceEdge) == "cdHit"
