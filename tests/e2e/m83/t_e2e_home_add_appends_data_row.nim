## GM4: the structural editor targets a plan-time data file.
##
## The editor writes PACKAGE rows (`add` / `remove`). Resource rows are
## hand-authored, exactly as `resources:` entries in `home.nim` are: no
## `repro home` command edits resources (Home-Profile-Intent-Layer.md
## §Structural Edit Contract); the second case checks a `remove` leaves them
## byte-identical.
##
## `e2e_home_add_appends_data_row` — `repro home add <pkg> --data FILE
## [--activity A] [--when PRED]` appends one `[[package]]` row to FILE, a
## data file the profile's `data:` section declares:
##
## * the file's existing bytes (a comment header, a row) are kept verbatim
##   and the row is appended in canonical form; `home.nim` is byte-identical;
## * the same command again is a no-op ("already has this row");
## * a FILE the profile does not declare is refused (exit 1) and not created;
##   `--if` (a data row's guard is its `when` field) and a `--when` naming a
##   non-built-in predicate are usage errors (exit 2); an unknown package is
##   refused (exit 1) — each leaving every file byte-identical;
## * the edit is what the planner then reads: `repro home list` shows the row
##   with its data file, and `repro home export --target` evaluates its guard
##   (present for aarch64-darwin, absent for x86_64-linux).
##
## Falsifying mutation (performed when this gate was written, see the
## milestone file): `runHomeAddDataRow` skipping the `dataFileRefs`
## declaration check — red: the undeclared file is created.
##
## No mocks: real `build/bin/repro`, real Nim, real filesystem.
## `REPRO_HOME_PACKAGE_CATALOG` (the documented catalog seam) names the
## packages `add` accepts.
##
## Platforms: every host (`--no-apply`; the export evaluation is for named
## targets, independent of the host).

import std/[json, os, strutils, unittest]

import ./profile_compile_edge_harness

const ProfileText = """
import repro_profile

profile "gm4DataEditor":
  data:
    "data/apps.toml"

  activity default:
    `gm4-base`

  hosts:
    "gm4-host": [tools]
"""

const AppsBefore = """# Applications, by canonical package name.
# Keep this header: the editor must not touch it.

[[package]]
name = "gm4-alpha"   # a trailing comment
activity = "tools"
"""

const AppendedRow = """
[[package]]
name = "gm4-gamma"
activity = "tools"
when = "macos"
"""

proc packageNames(evaluation: JsonNode): seq[string] =
  for p in evaluation["packages"]:
    result.add p["name"].getStr

suite "GM4: structural editor and data files":

  test "e2e_home_add_appends_data_row":
    let sb = newProfileSandbox("gm4-data-editor", ProfileText)
    defer: sb.dispose()
    sb.writeProfileFile("data/apps.toml", AppsBefore)
    let env = sb.fixturePackageEnv(["gm4-base", "gm4-alpha", "gm4-gamma"])
    let appsPath = sb.profileDir / "data" / "apps.toml"
    let homeBefore = readFile(sb.profilePath)

    proc add(args: openArray[string]): ReproRun =
      result = sb.runRepro(@["home", "add"] & @args, host = "gm4-host",
        extraEnv = env)
      checkpoint("repro home add " & args.join(" ") & " -> " &
        $result.exitCode & "\n" & result.stdout & result.stderr)

    # Refusals first: each leaves every file as it was.
    let undeclared = add(["gm4-gamma", "--data", "data/other.toml",
      "--no-apply"])
    check undeclared.exitCode == 1
    check undeclared.stderr.contains("not declared")
    check not fileExists(sb.profileDir / "data" / "other.toml")
    let withIf = add(["gm4-gamma", "--data", "data/apps.toml", "--if",
      "macos", "--no-apply"])
    check withIf.exitCode == 2
    let userPred = add(["gm4-gamma", "--data", "data/apps.toml", "--when",
      "macos and onBattery", "--no-apply"])
    check userPred.exitCode == 2
    check userPred.stderr.contains("onBattery")
    let unknownPkg = add(["gm4-not-in-catalog", "--data", "data/apps.toml",
      "--no-apply"])
    check unknownPkg.exitCode == 1
    let escaping = add(["gm4-gamma", "--data", "../apps.toml", "--no-apply"])
    check escaping.exitCode == 2
    check readFile(appsPath) == AppsBefore
    check readFile(sb.profilePath) == homeBefore

    # The edit.
    let added = add(["gm4-gamma", "--data", "data/apps.toml", "--activity",
      "tools", "--when", "macos", "--no-apply"])
    check added.exitCode == 0
    check added.stdout.contains("added gm4-gamma to data/apps.toml")
    check readFile(appsPath) == AppsBefore & "\n" & AppendedRow
    check readFile(sb.profilePath) == homeBefore

    # Idempotent.
    let again = add(["gm4-gamma", "--data", "data/apps.toml", "--activity",
      "tools", "--when", "macos", "--no-apply"])
    check again.exitCode == 0
    check again.stdout.contains("already has this row")
    check readFile(appsPath) == AppsBefore & "\n" & AppendedRow

    # The planner reads the edit.
    let listed = sb.runRepro(["home", "list"], host = "gm4-host",
      extraEnv = env)
    checkpoint("list:\n" & listed.stdout & listed.stderr)
    check listed.exitCode == 0
    check listed.stdout.contains("gm4-gamma  activity=tools  when macos  " &
      "data=data/apps.toml")
    for (target, present) in [("aarch64-darwin", true),
                              ("x86_64-linux", false)]:
      let exported = sb.runRepro(["home", "export", "--format", "json",
        "--target", target], host = "gm4-host", extraEnv = env)
      checkpoint("export --target " & target & ":\n" & exported.stderr)
      require exported.exitCode == 0
      let names = packageNames(parseJson(exported.stdout)["evaluation"])
      check "gm4-alpha" in names
      check ("gm4-gamma" in names) == present

  test "e2e_home_remove_deletes_data_row":
    # `repro home remove <pkg> --data FILE` deletes the matching package
    # rows and nothing else: every other row (package or resource), comment
    # and blank line keeps its bytes, and an add followed by a remove gives
    # back the file it started from. Falsifying mutation (performed when this
    # case was written, see the milestone file): `removePackageRows` ignoring
    # `--activity` — red: the `desktop` row goes too.
    let sb = newProfileSandbox("gm4-data-remove", ProfileText)
    defer: sb.dispose()
    let middle = "[[package]]\nname = \"gm4-gamma\"   # also on Linux\n" &
      "activity = \"desktop\"\n"
    let resource = "# shared config\n[[resource]]\nkind = \"fs.userFile\"\n" &
      "hostFile = \"~/gm4.conf\"\ncontent = \"x\"\n"
    let original = AppsBefore & "\n" & middle & "\n" & resource
    sb.writeProfileFile("data/apps.toml", original)
    let env = sb.fixturePackageEnv(["gm4-base", "gm4-alpha", "gm4-gamma"])
    let appsPath = sb.profileDir / "data" / "apps.toml"
    let homeBefore = readFile(sb.profilePath)

    proc run(verb: string; args: openArray[string]): ReproRun =
      result = sb.runRepro(@["home", verb] & @args, host = "gm4-host",
        extraEnv = env)
      checkpoint("repro home " & verb & " " & args.join(" ") & " -> " &
        $result.exitCode & "\n" & result.stdout & result.stderr)

    # add then remove: byte-identical round trip.
    check run("add", ["gm4-gamma", "--data", "data/apps.toml", "--activity",
      "tools", "--when", "macos", "--no-apply"]).exitCode == 0
    check readFile(appsPath) == original & "\n" & AppendedRow
    let removed = run("remove", ["gm4-gamma", "--data", "data/apps.toml",
      "--activity", "tools", "--no-apply"])
    check removed.exitCode == 0
    check removed.stdout.contains("removed 1 row(s) for gm4-gamma")
    check readFile(appsPath) == original
    # Refusals leave the file alone.
    check run("remove", ["gm4-gamma", "--data", "data/apps.toml",
      "--activity", "tools", "--no-apply"]).exitCode == 1
    check run("remove", ["gm4-gamma", "--data", "data/apps.toml", "--if",
      "linux", "--no-apply"]).exitCode == 2
    check run("remove", ["gm4-gamma", "--data", "data/other.toml",
      "--no-apply"]).exitCode == 1
    check readFile(appsPath) == original
    # The middle row goes; the rows around it and the resource keep their
    # bytes.
    check run("remove", ["gm4-gamma", "--data", "data/apps.toml",
      "--no-apply"]).exitCode == 0
    check readFile(appsPath) == AppsBefore & "\n" & resource
    check readFile(sb.profilePath) == homeBefore
    let listed = sb.runRepro(["home", "list"], host = "gm4-host",
      extraEnv = env)
    check listed.exitCode == 0
    check not listed.stdout.contains("gm4-gamma")
    check listed.stdout.contains("gm4-alpha")
