## `export_nixos_fact_required`: `repro home export --target` of a profile
## whose guards reach the `nixos` predicate is refused (exit 3, naming
## `nixos`) while the fact is not stated, and selects per the stated fact when
## it is (`--nixos`, `--nixos=false`). Whether a Linux target is NixOS is not
## part of its system name, so it is never read as false.
##
## The fixture is `tests/fixtures/nixos-fact/` (README there):
##
## * `export.json` is what `build/bin/repro home export --host h` says about
##   the profile now (`--check` exit 0; rewritten with
##   `REPRO_UPDATE_INTENT_FIXTURES=1`);
## * each case of `cases.json` is what `--target <system> [--nixos[=false]]`
##   reports: the packages it selects, or exit 3 naming `nixos`;
## * a stated fact without a `--target` is a usage error (exit 2), and the
##   fact changes nothing for a target a guard does not reach it on.
##
## The Nix library's answer to the same cases is the flake check `lib-tests`,
## over the committed `export.json`; this gate keeps that file true.
##
## Vacuity: the fixture has stated-true, stated-false and refused cases, and
## selects different packages for the two stated values on one system.
##
## No mocks: the real `build/bin/repro` and the real Nim compiler. Platforms:
## every host (the evaluation targets are named, not the host's).

import std/[algorithm, json, os, sequtils, strutils, unittest]

import ./profile_compile_edge_harness

const
  FixtureRoot = ProjectRoot / "tests" / "fixtures" / "nixos-fact"
  UpdateEnvVar = "REPRO_UPDATE_INTENT_FIXTURES"

suite "the nixos fact is stated by a consumer or the evaluation is refused":

  test "export_nixos_fact_required":
    let sb = newProfileSandbox("nixos-fact",
      readFile(FixtureRoot / "profile" / "home.nim"))
    defer: sb.dispose()
    let cases = parseFile(FixtureRoot / "cases.json")
    let host = cases["host"].getStr
    let snapshot = FixtureRoot / "export.json"

    if getEnv(UpdateEnvVar) == "1":
      let fresh = sb.runRepro(["home", "export", "--format", "json"],
        host = host)
      require fresh.exitCode == 0
      writeFile(snapshot, fresh.stdout)
    # The committed snapshot is current.
    let checked = sb.runRepro(["home", "export", "--check", snapshot],
      host = host)
    checkpoint("--check -> " & $checked.exitCode & "\n" & checked.stderr)
    check checked.exitCode == 0

    var stated, refused = 0
    var statedPackages: seq[seq[string]]
    for c in cases["cases"]:
      let system = c["system"].getStr
      var args = @["home", "export", "--format", "json", "--target", system]
      if c.hasKey("nixos"):
        args.add(if c["nixos"].getBool: "--nixos" else: "--nixos=false")
      let r = sb.runRepro(args, host = host)
      checkpoint($args & " -> exit " & $r.exitCode & "\n" & r.stderr)
      if c{"refused"}.getBool:
        # Not stated: refused, and the diagnostic names the predicate.
        check r.exitCode == 3
        check r.stderr.contains("nixos")
        check r.stdout.len == 0
        inc refused
        continue
      require r.exitCode == 0
      var got = parseJson(r.stdout)["evaluation"]["packages"].getElems.mapIt(
        it["name"].getStr)
      got.sort()
      let expected = c["packages"].getElems.mapIt(it.getStr)
      check got == expected
      statedPackages.add got
      inc stated

    # A fact about the target host means nothing without a target.
    let noTarget = sb.runRepro(["home", "export", "--format", "json",
      "--nixos"], host = host)
    check noTarget.exitCode == 2
    check noTarget.stderr.contains("--target")

    # Vacuity.
    check stated >= 4
    check refused >= 2
    check statedPackages.deduplicate().len >= 3
