## GM4: a plan-time data file is validated, never partially applied.
##
## `e2e_data_file_rejects_unknown_predicate` — a row whose `when` names an
## identifier outside the built-in predicate grammar (here `headless`, which
## is a profile-side helper template with no evaluator, and `onBattery`, a
## would-be user predicate) is refused by `repro home apply --plan`,
## `repro home plan` and `repro home export`: exit 1, the diagnostic names
## the data file, the row, the `when` key and the identifier, and nothing is
## planned. Data rows cannot carry user predicates: nothing outside the
## profile's Nim code (this planner reading TOML, a Nix consumer) can
## evaluate one (Core-Invariants.md §Unrecognised Input Is Rejected, Not
## Skipped).
##
## `e2e_data_file_rejects_rows_outside_the_schema` — the fixed row schema
## is closed: an unknown row key, an unknown top-level table, a missing
## required key, a mistyped predicate (`host` alone) and a declared file that
## does not exist are each refused the same way.
##
## Negative control: the same profile with a built-in `when` (`linux or
## macos or windows`) plans successfully, so each refusal is caused by the
## row under test.
##
## Falsifying mutation (performed when this gate was written, see the
## milestone file): `decodeRow` in `repro_home_intent/data_file.nim` not
## validating `when` (only parsing it) — red in every refusal of the first
## case: no diagnostic names the guard as non-built-in (the run fails later,
## in the planner's evaluator, or not at all).
##
## `e2e_data_section_refuses_paths_outside_the_profile` — the `data:`
## section itself only names files inside the profile directory.
##
## `e2e_remote_bundle_refuses_data_profiles` — the remote-apply bundle
## builder, which reads `home.nim` as text and so cannot expand `data:`,
## refuses such a profile instead of building a bundle without its rows.
##
## No mocks: real `build/bin/repro`, real Nim, real filesystem.
##
## Platforms: every host.

import std/[os, strutils, unittest]

import ./profile_compile_edge_harness

const ProfileText = """
import repro_profile

profile "gm4DataValidation":
  data:
    "data/apps.toml"

  activity default:
    `gm4-base`
"""

proc row(extra: string): string =
  "[[package]]\nname = \"gm4-alpha\"\nactivity = \"default\"\n" & extra

proc refused(sb: ProfileSandbox; args: openArray[string];
             needles: openArray[string]): bool =
  ## Whether `repro <args>` refused the profile: exit 1, every needle in the
  ## diagnostic, nothing planned. Each missing condition is named.
  let r = sb.runRepro(args,
    extraEnv = sb.fixturePackageEnv(["gm4-base", "gm4-alpha"]))
  checkpoint("repro " & args.join(" ") & " -> " & $r.exitCode & "\n" &
    r.stdout & r.stderr)
  result = r.exitCode == 1 and not r.stdout.contains("gm4-alpha")
  for needle in needles:
    if not (r.stdout & r.stderr).contains(needle):
      checkpoint("missing from the diagnostic: " & needle)
      result = false

suite "GM4: data-file validation":

  test "e2e_data_file_rejects_unknown_predicate":
    let sb = newProfileSandbox("gm4-data-pred", ProfileText)
    defer: sb.dispose()
    # Negative control first: a built-in guard plans.
    sb.writeProfileFile("data/apps.toml",
      row("when = \"linux or macos or windows\"\n"))
    let ok = sb.runRepro(["home", "apply", "--plan"],
      extraEnv = sb.fixturePackageEnv(["gm4-base", "gm4-alpha"]))
    checkpoint("control:\n" & ok.stdout & ok.stderr)
    check ok.exitCode == 0
    check ok.stdout.contains("gm4-alpha")

    for ident in ["headless", "onBattery"]:
      sb.writeProfileFile("data/apps.toml",
        row("when = \"linux and " & ident & "\"\n"))
      for args in [@["home", "apply", "--plan"], @["home", "plan"],
                   @["home", "export", "--format", "json"]]:
        check sb.refused(args, ["data/apps.toml", "row 1", "`when`",
          "'" & ident & "'", "not a built-in predicate"])

  test "e2e_data_file_rejects_rows_outside_the_schema":
    let sb = newProfileSandbox("gm4-data-schema", ProfileText)
    defer: sb.dispose()
    let cases = [
      (row("pinned = true\n"), @["row 1", "`pinned`", "unknown key"]),
      (row("") & "\n[[app]]\nname = \"x\"\n",
        @["`app`", "unknown top-level key"]),
      ("[[package]]\nname = \"gm4-alpha\"\n",
        @["row 1", "`activity`", "required key missing"]),
      (row("when = \"host\"\n"), @["row 1", "`when`", "not a valid predicate"]),
      (row("version = 3\n"), @["row 1", "`version`", "expected a string"]),
      ("not = [valid", @["not valid TOML"])]
    for (content, needles) in cases:
      sb.writeProfileFile("data/apps.toml", content)
      check sb.refused(["home", "apply", "--plan"],
        @["data/apps.toml"] & needles)
    removeFile(sb.profileDir / "data" / "apps.toml")
    check sb.refused(["home", "apply", "--plan"],
      ["data/apps.toml", "does not exist"])

  test "e2e_data_section_refuses_paths_outside_the_profile":
    # The `data:` section names files relative to the profile directory and
    # inside it: the macro refuses anything else at compile time, naming the
    # path, so a reference that escapes the profile never reaches the
    # planner (the planner re-checks with the same rule, `dataFilePathProblem`).
    let sb = newProfileSandbox("gm4-data-path", ProfileText)
    defer: sb.dispose()
    for (bad, why) in [("../outside.toml", "inside the profile directory"),
                       ("/etc/apps.toml", "relative to the profile"),
                       ("data//apps.toml", "empty segment")]:
      writeFile(sb.profilePath, ProfileText.replace("data/apps.toml", bad))
      let r = sb.runRepro(["home", "apply", "--plan"])
      checkpoint(bad & " -> " & $r.exitCode & "\n" & r.stdout & r.stderr)
      check r.exitCode == 1
      check (r.stdout & r.stderr).contains(bad)
      check (r.stdout & r.stderr).contains(why)

  test "e2e_remote_bundle_refuses_data_profiles":
    # The remote-apply bundle builder (`repro home __build-bundle
    # --evaluate`, the source side of `repro home enable --host H --now`)
    # plans from `home.nim` read as text, not through the compile that
    # expands `data:`. Building a bundle without the rows would silently
    # drop part of the profile, so it refuses, naming the files and the
    # remedy (Home-Profile-Intent-Layer.md, remote activation limits).
    # Negative control: the same profile without its `data:` section builds
    # a bundle, so the refusal is caused by the section.
    let sb = newProfileSandbox("gm4-data-bundle", ProfileText)
    defer: sb.dispose()
    sb.writeProfileFile("data/apps.toml", row(""))
    let env = sb.fixturePackageEnv(["gm4-base", "gm4-alpha"])
    let args = ["home", "__build-bundle", "--evaluate", "--target-host",
      "gm4-target", "--profile-dir", sb.profileDir, "--home-dir",
      sb.root / "target-home"]
    let refusedRun = sb.runRepro(args, extraEnv = env)
    checkpoint("with data: -> " & $refusedRun.exitCode & "\n" &
      refusedRun.stdout & refusedRun.stderr)
    check refusedRun.exitCode == 1
    check refusedRun.stderr.contains("data/apps.toml")
    check refusedRun.stderr.contains("cannot expand")
    check refusedRun.stderr.contains("`repro home apply` on the host itself")
    check not refusedRun.stdout.contains("bundleDigest")
    writeFile(sb.profilePath, ProfileText.replace(
      "  data:\n    \"data/apps.toml\"\n\n", ""))
    let control = sb.runRepro(args, extraEnv = env)
    checkpoint("without data: -> " & $control.exitCode & "\n" &
      control.stdout & control.stderr)
    check control.exitCode == 0
    check control.stdout.contains("bundleDigest")
