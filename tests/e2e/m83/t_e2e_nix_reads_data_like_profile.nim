## GM5: `reprobuild.lib.readData` selects a data file's rows exactly as the
## profile planner does, and refuses exactly the files the planner refuses.
##
## `e2e_nix_reads_data_like_profile`, for every case under
## `tests/fixtures/data-files/` (README there; the cases GM4's planner gate
## `t_data_file_row_selection_fixtures` also reads):
##
## * PLANNER SIDE, computed by running Reprobuild, not read from the fixture:
##   a profile whose `data:` section names the case's `data.toml` and whose
##   `hosts:` is the case's `hosts` map is exported with `build/bin/repro home
##   export --target <system>` for each evaluation's host and system; the
##   selected set is the evaluation's package names (and resource addresses).
## * NIX SIDE: `nix eval` of this checkout's `nix/lib` (`readData`, the same
##   files the flake exports as `reprobuild.lib`) over the same `data.toml`,
##   host, system and `hosts` map.
## * `row-selection`: the two package sets are equal, and equal to the
##   fixture's expectation; and each selected package carries the same
##   version, binaries and activity on both sides (for a package several
##   rows select, the row the planner keeps -- case `duplicate-metadata`). A file with `[[resource]]` rows is the documented
##   exception: the planner selects them, readData REFUSES the file (resource
##   rows are constructor calls only Reprobuild evaluates; the spec requires
##   select-as-the-planner-does or refuse, never ignore) -- asserted as such.
## * `row-rejection`: `repro home export` exits 1 naming every listed
##   substring, and readData refuses with every listed substring (or, for a
##   file with resource rows, with the resource-row refusal).
##
## Falsifying mutation (performed when this gate was written; see the
## milestone file): readData's selection ignoring a row's `when`
## (`applies` in nix/lib/data.nix) -- red in every guard case.
##
## Vacuity: at least five selection cases are compared set-for-set, with
## non-empty and differing answers, and every rejection case is refused by
## both sides.
##
## No mocks: the real `build/bin/repro` (compile edge, planner, export), the
## real `nix`. Platforms: Linux and macOS (the hosts with Nix); on Windows
## the gate is not compiled in -- Nix does not run there; home-pc and m1 run
## it.

import std/[algorithm, json, os, sequtils, strutils, unittest]

import ./profile_compile_edge_harness
import ./nix_lib_support

const
  FixtureRoot = ProjectRoot / "tests" / "fixtures" / "data-files"
  ResourceRefusal = "does not read `[[resource]]` rows"

proc caseDirs(group: string): seq[string] =
  for kind, path in walkDir(FixtureRoot / group):
    if kind == pcDir:
      result.add path
  result.sort()

proc profileText(hosts: JsonNode): string =
  ## A profile that is the data file plus the hosts map, as the fixture
  ## README defines a case (no compiled activity bodies).
  result = "import repro_profile\n\nprofile \"gm5DataFixture\":\n" &
    "  data:\n    \"data.toml\"\n"
  if hosts != nil and hosts.len > 0:
    result.add "\n  hosts:\n"
    for host, activities in hosts:
      result.add "    " & escapeJson(host) & ": [" &
        activities.getElems.mapIt(it.getStr).join(", ") & "]\n"

proc hasResourceRows(dir: string): bool =
  readFile(dir / "data.toml").contains("[[resource]]")

proc nixReadData(dir: string; hosts: JsonNode;
                 evaluations: seq[(string, string)]): JsonNode =
  ## readData for each (host, system): `{ names }` or `{ error }`.
  var evals = newJArray()
  for (host, system) in evaluations:
    evals.add %*{"host": host, "system": system}
  nixEvalJson("""
    args:
    let lib = """ & nixLibExpr() & """; in
    map (e:
      let r = lib.internal.readDataResult {
        path = /. + args.path;
        inherit (e) host system;
        hosts = args.hosts;
      };
      in if r ? error then { inherit (r) error; } else { inherit (r) names packages; })
    args.evaluations
    """, %*{"path": dir / "data.toml",
      "hosts": (if hosts.isNil: newJObject() else: hosts),
      "evaluations": evals})

when defined(linux) or defined(macosx):
  suite "GM5: readData selects rows like the profile planner":

    test "e2e_nix_reads_data_like_profile":
      let sb = newProfileSandbox("gm5-readdata", profileText(nil))
      defer: sb.dispose()

      var compared, nonEmpty = 0
      var answers: seq[seq[string]]
      for dir in caseDirs("row-selection"):
        let name = dir.extractFilename
        let caseJson = parseFile(dir / "case.json")
        let hosts = caseJson{"hosts"}
        writeFile(sb.profilePath, profileText(hosts))
        sb.writeProfileFile("data.toml", readFile(dir / "data.toml"))
        var pairs: seq[(string, string)]
        for evaluation in caseJson["evaluations"]:
          pairs.add (evaluation["host"].getStr, evaluation["system"].getStr)
        let nix = nixReadData(dir, hosts, pairs)
        require nix.len == pairs.len
        for i, (host, system) in pairs:
          # The planner's answer, from a real export.
          let r = sb.runRepro(["home", "export", "--format", "json",
            "--target", system], host = host)
          checkpoint(name & ": " & host & " @ " & system & " -> exit " &
            $r.exitCode & "\n" & r.stderr)
          require r.exitCode == 0
          let evaluation = parseJson(r.stdout)["evaluation"]
          var planner = evaluation["packages"].getElems.mapIt(
            it["name"].getStr).deduplicate()
          planner.sort()
          let expected = caseJson["evaluations"][i]["packages"].getElems.mapIt(
            it.getStr)
          check planner == expected
          checkpoint(name & ": nix -> " & $nix[i])
          if hasResourceRows(dir):
            # The planner selected the resource rows; readData refuses the
            # file instead of ignoring them.
            check evaluation["resources"].len > 0
            check nix[i].hasKey("error")
            check nix[i]{"error"}.getStr.contains(ResourceRefusal)
          else:
            require nix[i].hasKey("names")
            let fromNix = nix[i]["names"].getElems.mapIt(it.getStr)
            check fromNix == planner
            # The metadata of each selected package, not only its name.
            var plannerPackages = evaluation["packages"].getElems.mapIt(
              %*{"name": it["name"], "version": it["version"],
                 "binaries": it["binaries"], "activity": it["activity"]})
            plannerPackages.sort(proc (a, b: JsonNode): int =
              cmp(a["name"].getStr, b["name"].getStr))
            check nix[i]["packages"] == %plannerPackages
            inc compared
            if planner.len > 0:
              inc nonEmpty
            answers.add planner

      var refusedBoth = 0
      for dir in caseDirs("row-rejection"):
        let name = dir.extractFilename
        let caseJson = parseFile(dir / "case.json")
        writeFile(sb.profilePath, profileText(nil))
        sb.writeProfileFile("data.toml", readFile(dir / "data.toml"))
        let r = sb.runRepro(["home", "export", "--format", "json"])
        checkpoint(name & ": planner exit " & $r.exitCode & "\n" & r.stderr)
        check r.exitCode == 1
        let nix = nixReadData(dir, newJObject(), @[("h", "x86_64-linux")])
        let message = nix[0]{"error"}.getStr
        checkpoint(name & ": nix -> " & message)
        var bothNamed = r.exitCode == 1 and message.len > 0
        for needle in caseJson["error"]:
          check r.stderr.contains(needle.getStr)
          if not hasResourceRows(dir):
            check message.contains(needle.getStr)
            bothNamed = bothNamed and message.contains(needle.getStr)
        if hasResourceRows(dir):
          check message.contains(ResourceRefusal)
        if bothNamed:
          inc refusedBoth

      # Vacuity.
      check compared >= 15
      check nonEmpty >= 10
      check answers.deduplicate().len >= 5
      check refusedBoth == caseDirs("row-rejection").len
