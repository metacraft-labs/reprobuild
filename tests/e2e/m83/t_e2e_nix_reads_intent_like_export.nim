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
    ## Evaluated in every case. A case may declare more (`caseHosts`).
  Systems = ["x86_64-linux", "aarch64-linux", "x86_64-darwin",
             "aarch64-darwin", "x86_64-windows", "aarch64-windows"]
  UpdateEnvVar = "REPRO_UPDATE_INTENT_FIXTURES"

proc caseHosts(name: string): seq[string] =
  ## The hosts evaluated for case `name`: `Hosts`, plus the `neutral`
  ## case's two add-on hosts (ReproOS add-on mode: `rpi` says `system:
  ## addOn`, `validator` the block form selecting system activities) and its
  ## `full` block-form host (`pc-full`), so the
  ## Nix library's reading of `evaluation.system` is compared for every
  ## mode.
  result = @Hosts
  if name == "neutral":
    result.add @["rpi", "validator", "pc-full"]

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
      check cases.mapIt(it.extractFilename) ==
        @["compile-time", "concerns", "neutral"]
      for dir in cases:
        let name = dir.extractFilename
        let hosts = caseHosts(name)
        let sb = newProfileSandbox("gm5-intent-" & name,
          readFile(dir / "profile" / "home.nim"))
        defer: sb.dispose()
        sb.copyProfile(dir / "profile")
        let snapshot = dir / "export.json"
        # GM7: the concerns case classifies its packages against the fixture
        # catalog beside its profile (the sandbox copy has no sibling).
        let caseEnv =
          if name == "concerns":
            @[("REPROBUILD_PACKAGES_ROOT", dir / "reprobuild-packages")]
          else:
            newSeq[(string, string)]()
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
              host = "m1", extraEnv = caseEnv)
            require fresh.exitCode == 0
            writeFile(snapshot, fresh.stdout)
          let checked = sb.runRepro(["home", "export", "--check", snapshot],
            host = "m1", extraEnv = caseEnv)
          checkpoint(name & ": --check -> " & $checked.exitCode & "\n" &
            checked.stderr)
          check checked.exitCode == 0

          # 2. Reprobuild's evaluations equal the committed ones.
          evaluations = newJObject()
          for host in hosts:
            evaluations[host] = newJObject()
            for system in Systems:
              let r = sb.runRepro(["home", "export", "--format", "json",
                "--target", system], host = host, extraEnv = caseEnv)
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
          for host in hosts:
            for system in Systems:
              checkpoint(name & ": committed " & host & " @ " & system)
              check committed[host][system] == evaluations[host][system]
        else:
          # The committed export does not describe this host's platform, so
          # this host's own export must say the converse: the snapshot's
          # compiling platform is not `same` for it, and --target refuses it.
          let fresh = sb.runRepro(["home", "export", "--format", "json"],
            host = "m1", extraEnv = caseEnv)
          require fresh.exitCode == 0
          let freshDoc = parseJson(fresh.stdout)
          checkpoint(name & ": exported on " & hostSystem & ", platforms " &
            $freshDoc["platforms"])
          check freshDoc["provenance"]["compile"]["target"].getStr ==
            hostSystem
          check freshDoc["platforms"][snapshotTarget].getStr != "same"
          let refused = sb.runRepro(["home", "export", "--format", "json",
            "--target", snapshotTarget], host = "m1", extraEnv = caseEnv)
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
          """, %*{"snapshot": snapshot, "hosts": hosts, "systems": Systems})
        var refused, evaluated, undeclared = 0
        for host in hosts:
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
        # without `server` (`neutral`), `server` is undeclared: refused on
        # every system, on both sides. The `compile-time` profile has no
        # registry, so there `server` is evaluated with `default` alone --
        # the host-agnostic control. The `concerns` profile declares
        # `server` (it gives Reprobuild the packages there).
        check evaluated > 0
        if committedDoc["intent"]["hosts"].len > 0 and
            not committedDoc["intent"]["hosts"].hasKey("server"):
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
        if name == "neutral":
          # GM10 + add-on mode: every value of `system:` reaches every
          # evaluation -- and, through step 3, the Nix library -- with its
          # mode and system-activity selection. The modes differ, so "every
          # host the same" cannot pass.
          for system in Systems:
            check evaluations["m1"][system]["system"] == %*{
              "managed": "elsewhere", "managedBy": "example-org/infra",
              "mode": "managedElsewhere", "activities": []}
            check evaluations["home-pc"][system]["system"] == %*{
              "managed": "here", "managedBy": nil, "mode": "full",
              "activities": ["default"]}
            check evaluations["rpi"][system]["system"] == %*{
              "managed": "here", "managedBy": nil, "mode": "addOn",
              "activities": ["default"]}
            check evaluations["validator"][system]["system"] == %*{
              "managed": "here", "managedBy": nil, "mode": "addOn",
              "activities": ["default", "web", "backup"]}
            check evaluations["pc-full"][system]["system"] == %*{
              "managed": "here", "managedBy": nil, "mode": "full",
              "activities": ["default", "web"]}
        if name == "concerns":
          # GM7: the hosts that declare `applies:` carry it in every
          # evaluation, with each package's concern; the one that declares
          # no `applies:` carries neither. The export carries the classification the Nix
          # side reads it with.
          for system in Systems:
            check evaluations["m1"][system]["applies"] ==
              %*["applications", "environment"]
            check evaluations["server"][system]["applies"] == %*["packages"]
            check not evaluations["home-pc"][system].hasKey("applies")
            for host in ["m1", "server"]:
              for p in evaluations[host][system]["packages"]:
                check p.hasKey("concern") and p.hasKey("resolved")
            for p in evaluations["home-pc"][system]["packages"]:
              check not p.hasKey("concern")
          let doc = parseFile(snapshot)
          check doc["intent"]["hostApplies"] ==
            %*{"m1": ["applications", "environment"], "server": ["packages"]}
          check doc["concerns"]["resourceKinds"]["fs.managedBlock"] ==
            %"environment"
          check doc["concerns"]["configOverrides"] == %"files"
          # The per-package classification (Open question 9): the fixture
          # catalog's disk image is an application on the darwin targets
          # only, and every system is classified.
          for system in Systems:
            let apps = doc["concerns"]["packages"][system]["applications"]
            if system.endsWith("-darwin"):
              check apps == %*["gm7app"]
            else:
              check apps.len == 0
          var app: JsonNode
          for p in evaluations["m1"]["aarch64-darwin"]["packages"]:
            if p["name"].getStr == "gm7app":
              app = p
          require not app.isNil
          check app["concern"] == %"applications"
          check app["resolved"] == %true
