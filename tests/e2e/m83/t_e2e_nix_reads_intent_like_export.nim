## GM5: `reprobuild.lib.readIntent` evaluates an export exactly as
## `repro home export --target` does, and the export fixtures it is tested
## against are current.
##
## `e2e_nix_reads_intent_like_export`, for every case under
## `tests/fixtures/intent-exports/` (README there):
##
## * the committed `export.json` is what `build/bin/repro home export --host
##   m1` says about the case's profile now (`--check` exit 0);
## * for every host (`m1`, `home-pc`, `server`) and every target system,
##   `repro home export --target` (Reprobuild's `evaluateHomeExport`) gives
##   exactly the committed `evaluations.json` entry -- an evaluation, packages
##   sorted by name, `{ "refused": true }` for exit 3, or
##   `{ "undeclaredHost": true }` when the export refuses the host because the
##   profile's `hosts:` registry does not name it (`server`; spec Open
##   question 6, answered by GM8);
## * the Nix library, reading only `export.json`, evaluates every pair to the
##   same value and refuses exactly the refused ones (`nix eval` of this
##   checkout's `nix/lib`).
##
## Steps one and two need a host whose platform the committed export
## describes: the `compile-time` case was exported on Linux, and a darwin
## compile takes its `when defined(macosx)` branch, so on macOS the gate
## checks the converse for that case -- its own export marks the snapshot's
## compiling platform as not `same`, and `--target` refuses it -- and runs
## step three as everywhere.
##
## The flake check `lib-tests` repeats the last comparison against the
## committed files on every system the flake supports, without running
## `repro`; this gate is what keeps those files true. Run with
## `REPRO_UPDATE_INTENT_FIXTURES=1` to rewrite them from a fresh export.
##
## Vacuity: both cases are found; the neutral case has a non-empty
## evaluation per host with packages, resources and config overrides, and
## the compile-time case has refusals and evaluations.
##
## No mocks: the real `build/bin/repro`, the real Nim compiler, the real
## `nix`. Platforms: Linux and macOS (the hosts with Nix). On Windows the
## gate is not compiled in: Nix does not run there; home-pc and m1 run it.

import std/[algorithm, json, os, sequtils, strutils, unittest]

import repro_profile_compile

import ./profile_compile_edge_harness
import ./nix_lib_support

const
  FixtureRoot = ProjectRoot / "tests" / "fixtures" / "intent-exports"
  Hosts = ["m1", "home-pc", "server"]
  Systems = ["x86_64-linux", "aarch64-linux", "x86_64-darwin",
             "aarch64-darwin", "x86_64-windows", "aarch64-windows"]
  UpdateEnvVar = "REPRO_UPDATE_INTENT_FIXTURES"

proc caseDirs(): seq[string] =
  for kind, path in walkDir(FixtureRoot):
    if kind == pcDir:
      result.add path
  result.sort()

proc copyProfile(sb: ProfileSandbox; source: string) =
  for path in walkDirRec(source):
    sb.writeProfileFile(path.relativePath(source).replace('\\', '/'),
      readFile(path))

proc normalized(evaluation: JsonNode): JsonNode =
  ## Reprobuild's evaluation with its packages sorted by name: the planner
  ## orders them topologically over extractor edges, which only its resolver
  ## can compute, and consumers must not depend on the order.
  result = evaluation.copy()
  var packages = result["packages"].getElems()
  packages.sort(proc (a, b: JsonNode): int =
    cmp(a["name"].getStr, b["name"].getStr))
  result["packages"] = %packages

when defined(linux) or defined(macosx):
  suite "GM5: the Nix helper library reads an export like repro does":

    test "e2e_nix_reads_intent_like_export":
      let update = getEnv(UpdateEnvVar) == "1"
      let cases = caseDirs()
      check cases.mapIt(it.extractFilename) == @["compile-time", "neutral"]
      for dir in cases:
        let name = dir.extractFilename
        let sb = newProfileSandbox("gm5-intent-" & name,
          readFile(dir / "profile" / "home.nim"))
        defer: sb.dispose()
        sb.copyProfile(dir / "profile")
        let snapshot = dir / "export.json"
        let evaluationsFile = dir / "evaluations.json"
        let hostSystem = compilingPlatformSystem()
        let committedDoc = parseFile(snapshot)
        let snapshotTarget =
          committedDoc["provenance"]["compile"]["target"].getStr
        # Steps 1 and 2 re-derive the committed files on THIS host, which is
        # only possible where the committed export describes this host's
        # platform. The compile-time case was exported on Linux, and a darwin
        # compile takes its `when defined(macosx)` branch: there a fresh
        # export legitimately differs, so the host checks the dependence from
        # its own side instead (below). Every host runs step 3.
        let describesHost = hostSystem == snapshotTarget or
          committedDoc["platforms"]{hostSystem}.getStr == "same"
        if update:
          require describesHost

        var evaluations: JsonNode
        if describesHost:
          # 1. The snapshot is current.
          if update:
            let fresh = sb.runRepro(["home", "export", "--format", "json"],
              host = "m1")
            require fresh.exitCode == 0
            writeFile(snapshot, fresh.stdout)
          let checked = sb.runRepro(["home", "export", "--check", snapshot],
            host = "m1")
          checkpoint(name & ": --check -> " & $checked.exitCode & "\n" &
            checked.stderr)
          check checked.exitCode == 0

          # 2. Reprobuild's evaluations equal the committed ones.
          evaluations = newJObject()
          for host in Hosts:
            evaluations[host] = newJObject()
            for system in Systems:
              let r = sb.runRepro(["home", "export", "--format", "json",
                "--target", system], host = host)
              checkpoint(name & ": " & host & " @ " & system & " -> " &
                $r.exitCode & "\n" & r.stderr)
              if r.exitCode == 3:
                evaluations[host][system] = %*{"refused": true}
              elif r.exitCode == 1 and r.stderr.contains("is not declared " &
                  "in the profile's hosts: registry"):
                evaluations[host][system] = %*{"undeclaredHost": true}
              else:
                require r.exitCode == 0
                evaluations[host][system] =
                  normalized(parseJson(r.stdout)["evaluation"])
          if update:
            writeFile(evaluationsFile, evaluations.pretty(2) & "\n")
          let committed = parseFile(evaluationsFile)
          for host in Hosts:
            for system in Systems:
              checkpoint(name & ": committed " & host & " @ " & system)
              check committed[host][system] == evaluations[host][system]
        else:
          # The committed export does not describe this host's platform, so
          # this host's own export must say the converse: the snapshot's
          # compiling platform is not `same` for it, and --target refuses it.
          let fresh = sb.runRepro(["home", "export", "--format", "json"],
            host = "m1")
          require fresh.exitCode == 0
          let freshDoc = parseJson(fresh.stdout)
          checkpoint(name & ": exported on " & hostSystem & ", platforms " &
            $freshDoc["platforms"])
          check freshDoc["provenance"]["compile"]["target"].getStr ==
            hostSystem
          check freshDoc["platforms"][snapshotTarget].getStr != "same"
          let refused = sb.runRepro(["home", "export", "--format", "json",
            "--target", snapshotTarget], host = "m1")
          check refused.exitCode == 3
          evaluations = parseFile(evaluationsFile)

        # 3. The Nix library, from export.json alone, agrees pair by pair.
        let nixResults = nixEvalJson("""
          args:
          let
            lib = """ & nixLibExpr() & """;
            doc = builtins.fromJSON (builtins.readFile args.snapshot);
          in
          builtins.listToAttrs (map (host: {
            name = host;
            value = builtins.listToAttrs (map (system: {
              name = system;
              value =
                if lib.internal.hostRefusalReason doc host != null
                then { undeclaredHost = true; }
                else if lib.internal.refusalReason doc system != null
                then { refused = true; }
                else lib.evaluateExport doc system host;
            }) args.systems);
          }) args.hosts)
          """, %*{"snapshot": snapshot, "hosts": Hosts, "systems": Systems})
        var refused, evaluated, undeclared = 0
        for host in Hosts:
          for system in Systems:
            let want = evaluations[host][system]
            checkpoint(name & ": nix " & host & " @ " & system & "\n  nix: " &
              $nixResults[host][system] & "\n  repro: " & $want)
            check nixResults[host][system] == want
            if want.hasKey("refused"):
              inc refused
            elif want.hasKey("undeclaredHost"):
              inc undeclared
            else:
              inc evaluated

        # Vacuity. Where the case's profile declares a hosts: registry
        # (`neutral`), `server` is undeclared: refused on every system, on
        # both sides. The `compile-time` profile has no registry, so there
        # `server` is evaluated with `default` alone -- the host-agnostic
        # control.
        check evaluated > 0
        if committedDoc["intent"]["hosts"].len > 0:
          check undeclared == Systems.len
          for system in Systems:
            check evaluations["server"][system].hasKey("undeclaredHost")
        else:
          check undeclared == 0
        if name == "compile-time":
          check refused > 0
        else:
          check refused == 0
          for host in ["m1", "home-pc"]:
            let e = evaluations[host]["x86_64-linux"]
            check e["packages"].len > 0
            check e["resources"].len > 0
            check e["configOverrides"].len > 0
