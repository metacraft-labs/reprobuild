## A registry crate's rustc edge built from a unit of cargo's plan
## (`registryCrateUnitEdge`) refuses a unit that is not a compile of this
## crate's library from its store prefix, and creates nothing when it does.
##
## Setup: one real `.crate` made by `cargo package` (a library with a
## `src/main.rs` beside its `src/lib.rs`, so a binary's crate root exists in
## the prefix), put in a directory mirror by its checksum and fetched into a
## private store root by the production fetch. A well-formed unit, shaped as
## the plan gives one (cargo's argv for a dependency, run in the prefix,
## writing an rlib, an rmeta and a dep-info file), is accepted: the positive
## control. Each case then changes one thing about it and expects the
## refusal (`rcrUnit`) naming what is wrong, with no output directory made:
## a working directory other than the prefix; a crate name other than the
## manifest's library; the binary's root, or no crate root at all; a remap
## of its own; a missing rlib or rmeta; a crate type other than `lib` or
## `rlib`.
##
## Falsifying mutations (applied, observed to fail, reverted): deleting every
## planned-unit refusal of `checkRegistryCrateUnit` fails every case but the
## control; dropping its crate-type check alone fails the binary and cdylib
## cases.
##
## No mocks: the production fetch and store, a real crate. Nothing is
## compiled; the edge is only constructed.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_core/ambient_execution
import repro_test_support/reasoned_skip

import ./crate_fixtures
import repro_lock/identity

proc unitFor(prefix, outDir: string): RegistryCrateUnit =
  let h = "00112233aabbccdd"
  RegistryCrateUnit(governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      hash: h, crateName: "rqu",
    argv: @["rustc", "--crate-name", "rqu", "--edition=2021",
      prefix / "src" / "lib.rs", "--crate-type", "lib",
      "--emit=dep-info,metadata,link", "-C", "embed-bitcode=no",
      "-C", "metadata=" & h, "-C", "extra-filename=-" & h,
      "--out-dir", outDir, "--cap-lints", "allow"],
    cwd: prefix, env: @["CARGO_PKG_NAME=rqu"], outDir: outDir,
    outputs: @[outDir / ("librqu-" & h & ".rlib"),
      outDir / ("librqu-" & h & ".rmeta"), outDir / ("rqu-" & h & ".d")],
    isolateHostEnvironment: true)

proc refusal(row: CrateRow; store: string; u: RegistryCrateUnit): string =
  ## The refusal's message, or "" when the unit was accepted.
  try:
    discard registryCrateUnitEdge(row, store, u)
  except RegistryCrateRefusal as e:
    check e.reason == rcrUnit
    return e.msg

let hasCargo = uncontrolledFindExe("cargo").len > 0

suite "a registry crate's edge from a planned unit":
  test "a unit that is not this crate's library compile is refused":
    if not hasCargo:
      skip("no cargo on PATH: the fixture crate is made by cargo package")
    else:
      let work = createTempDir("registry-unit-edge-", "")
      defer: removeTestTree(work)
      let bytes = packCrate(work, "rqu", "0.1.0", @[
        ("src/lib.rs", "pub fn u() {}\n"), ("src/main.rs", "fn main() {}\n")])
      let row = CrateRow(name: "rqu", version: "0.1.0",
        cksum: sha256Hex(bytes))
      let mirror = work / "mirror"
      createDir(parentDir(mirror / crateObjectPath(row.cksum)))
      writeFile(mirror / crateObjectPath(row.cksum), bytes)
      let store = work / "store"
      var cfg = defaultCrateFetchConfig(work / "state", @[parseMirror(mirror)])
      cfg.storeRoot = store
      cfg.originBase = ""
      let fetched = fetchLockedCrates(@[row], cfg)
      require fetched.ok
      let prefix = fetched.crates[0].prefix

      # The positive control.
      let good = unitFor(prefix, work / "out-good")
      let e = registryCrateUnitEdge(row, store, good)
      check e.argvDifference == @["--remap-path-prefix=" & prefix &
        "=rqu-0.1.0"]
      check e.action.outputs == good.outputs[0 .. 1]

      proc changed(f: proc (u: var RegistryCrateUnit)): RegistryCrateUnit =
        result = unitFor(prefix, work / "out-refused")
        f(result)
      let cases = [
        ("a working directory other than the prefix",
          changed(proc (u: var RegistryCrateUnit) = u.cwd = work),
          "not in the crate's prefix"),
        ("another crate name",
          changed(proc (u: var RegistryCrateUnit) = u.crateName = "other"),
          "not the library rqu"),
        ("the binary's crate root",
          changed(proc (u: var RegistryCrateUnit) =
            u.argv[4] = prefix / "src" / "main.rs"),
          "does not compile the crate root"),
        ("no crate root",
          changed(proc (u: var RegistryCrateUnit) = u.argv.delete(4)),
          "does not compile the crate root"),
        ("a remap of its own",
          changed(proc (u: var RegistryCrateUnit) =
            u.argv.add "--remap-path-prefix=" & prefix & "=x"),
          "already passes --remap-path-prefix"),
        ("no rlib",
          changed(proc (u: var RegistryCrateUnit) = u.outputs.delete(0)),
          "both an rlib and an rmeta"),
        ("no rmeta",
          changed(proc (u: var RegistryCrateUnit) = u.outputs.delete(1)),
          "both an rlib and an rmeta"),
        ("a binary crate type",
          changed(proc (u: var RegistryCrateUnit) = u.argv[6] = "bin"),
          "has crate type bin"),
        ("a cdylib crate type",
          changed(proc (u: var RegistryCrateUnit) = u.argv[6] = "cdylib"),
          "has crate type cdylib")]
      for (what, unit, expected) in cases:
        checkpoint what
        let msg = refusal(row, store, unit)
        checkpoint msg
        check expected in msg
        check not dirExists(work / "out-refused")
