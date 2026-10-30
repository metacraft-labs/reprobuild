## ReproOS add-on mode: the registry's `system:` value round-trips through
## every layer that carries it, and a schema-4 export is refused.
##
## `t_addon_registry_mode_round_trip` (the Reprobuild half; the dotfiles
## readers have their own gate, see below), against the real
## `build/bin/repro` and the real `nix`:
##
## The home profile's `hosts:` registry declares one host per value of
## `system:` -- absent (`rt-full`), `managedElsewhere("example-org/rt")`
## (`rt-elsewhere`), `managedElsewhere` without a pointer (`rt-nopointer`),
## `addOn` (`rt-addon`), the indented block form (`rt-block`), the inline
## block form (`rt-inline`), the spelled `full` (`rt-fullshort`, the same as
## absent) and the `full` block form selecting a system activity
## (`rt-fullblock`, spec §13 decision 17).
##
## 1. Macro -> export: `repro home export` writes schema 5, and
##    `intent.hostSystems` carries exactly the seven declarations, each with
##    `mode`, `managedBy` and `activities`; `--target` reports
##    `evaluation.system` for every host (`full` / `managedElsewhere` /
##    `addOn`, with the system activities). `--check` sees an edit of an
##    add-on host's activity list.
## 2. Macro -> RBPI -> planner: `repro infra plan` reads the registry through
##    the compiled RBPI envelope and reports each add-on host's mode and
##    selection (Debian 13 base), so the value survived the binary encoding
##    too (and the managed-elsewhere hosts are refused there, naming the
##    pointer).
## 3. Export -> Nix reader: `reprobuild.lib.hostSystemManagement` reads, from
##    the export alone, exactly what Reprobuild's evaluation says for every
##    host, and `readIntent`'s evaluation carries the same `system`.
## 4. A schema-4 export is refused by the Nix reader (`hostSystemManagement`
##    and `readIntent`), both in its own shape (`systemManagedElsewhere`) and
##    as this document relabelled 4 -- it can never be read as "here".
## 5. The macro (`repro home export`) and the text parser behind the
##    structural editor (`repro home set ... --no-apply`, which loads the
##    profile with `repro_home_intent/parser`) refuse the same malformed
##    values, each naming the host and the reason: an empty or `default`-listing activity list, a block
##    without `mode:`, an unknown mode, `managedElsewhere` with activities,
##    `addOn("x")`.
##
## The dotfiles half -- `bin/host-system-management`, `bin/system-switch`
## and `bin/home-switch.ps1` reading schema 5 and refusing 4, and the
## falsifying mutation (the Nix reader mapping `addOn` to "here" makes the
## system-switch gate run `nixos-rebuild` on the add-on fixture host) -- is
## `tests/e2e_dotfiles_system_switch_refuses_unmanaged_hosts_by_name.sh` and
## `tests/e2e_home_switch_ps1_skips_system_scope_on_unmanaged_hosts.sh` in
## zah/dotfiles.
##
## Vacuity: the evaluations of the six hosts take three different modes, and
## the add-on hosts' activity lists differ, so a reader that answers one
## constant cannot pass.
##
## No mocks: real `repro`, real Nim, real `nix`, real files. The base the
## planner observes is chosen through the `os-release` seam
## (`addon_test_support`). Nothing is applied.
##
## Platforms: Linux and macOS (the hosts with Nix).

import std/[json, os, strutils, unittest]

import ../m83/profile_compile_edge_harness
import ../m83/nix_lib_support
import ./addon_test_support

const Registry = """
    "rt-full": [default]
    "rt-elsewhere":
      activities: [default]
      system: managedElsewhere("example-org/rt")
    "rt-nopointer":
      system: managedElsewhere
    "rt-addon":
      activities: [default]
      system: addOn
    "rt-block":
      system:
        mode: addOn
        activities: [web, backup]
      activities: [default]
    "rt-inline":
      system: {mode: addOn, activities: [monitoring]}
    "rt-fullshort":
      system: full
    "rt-fullblock":
      activities: [default]
      system: {mode: full, activities: [web]}
"""

proc homeProfile(hostsBlock: string): string =
  """
import repro_profile

profile "a6rtRegistry":
  activity default:
    a6rtnosuchpackage

  hosts:
""" & hostsBlock

const SystemProfile = """
import repro_profile

profile "a6rtSystem":
  activity web:
    resources:
      fsSystemFile(path = "/etc/a6rt-test/web.conf", content = "w\n",
        address = "webConf")
  activity backup:
    resources:
      fsSystemFile(path = "/etc/a6rt-test/backup.conf", content = "b\n",
        address = "backupConf")
  activity monitoring:
    resources:
      fsSystemFile(path = "/etc/a6rt-test/monitoring.conf", content = "m\n",
        address = "monitoringConf")
  resources:
    fsSystemFile(path = "/etc/a6rt-test/base.conf", content = "x\n",
      address = "baseConf")
"""

const
  Hosts = ["rt-full", "rt-elsewhere", "rt-nopointer", "rt-addon",
           "rt-block", "rt-inline", "rt-fullshort", "rt-fullblock"]
  ExpectedHostSystems = """{
    "rt-addon": {"mode": "addOn", "managedBy": null, "activities": []},
    "rt-block": {"mode": "addOn", "managedBy": null,
                 "activities": ["web", "backup"]},
    "rt-elsewhere": {"mode": "managedElsewhere",
                     "managedBy": "example-org/rt", "activities": []},
    "rt-fullblock": {"mode": "full", "managedBy": null,
                     "activities": ["web"]},
    "rt-fullshort": {"mode": "full", "managedBy": null, "activities": []},
    "rt-inline": {"mode": "addOn", "managedBy": null,
                  "activities": ["monitoring"]},
    "rt-nopointer": {"mode": "managedElsewhere", "managedBy": null,
                     "activities": []}}"""

proc expectedSystem(host: string): JsonNode =
  case host
  of "rt-full":
    %*{"managed": "here", "managedBy": nil, "mode": "full",
       "activities": ["default"]}
  of "rt-elsewhere":
    %*{"managed": "elsewhere", "managedBy": "example-org/rt",
       "mode": "managedElsewhere", "activities": []}
  of "rt-nopointer":
    %*{"managed": "elsewhere", "managedBy": nil,
       "mode": "managedElsewhere", "activities": []}
  of "rt-addon":
    %*{"managed": "here", "managedBy": nil, "mode": "addOn",
       "activities": ["default"]}
  of "rt-block":
    %*{"managed": "here", "managedBy": nil, "mode": "addOn",
       "activities": ["default", "web", "backup"]}
  of "rt-inline":
    %*{"managed": "here", "managedBy": nil, "mode": "addOn",
       "activities": ["default", "monitoring"]}
  of "rt-fullshort":
    %*{"managed": "here", "managedBy": nil, "mode": "full",
       "activities": ["default"]}
  of "rt-fullblock":
    %*{"managed": "here", "managedBy": nil, "mode": "full",
       "activities": ["default", "web"]}
  else:
    raise newException(ValueError, "no expectation for " & host)

when defined(linux) or defined(macosx):
  suite "ReproOS add-on mode: the registry mode round-trips":

    test "t_addon_registry_mode_round_trip":
      let sb = newProfileSandbox("a6rt", homeProfile(Registry))
      defer: sb.dispose()

      # 1. Macro -> export.
      let exported = sb.runRepro(["home", "export", "--format", "json"],
        host = "rt-full")
      checkpoint exported.stderr
      require exported.exitCode == 0
      let doc = parseJson(exported.stdout)
      check doc["schemaVersion"].getInt == 5
      check not doc["intent"].hasKey("systemManagedElsewhere")
      check doc["intent"]["hostSystems"] == parseJson(ExpectedHostSystems)
      var evaluations = newJObject()
      var modes: seq[string]
      for host in Hosts:
        let target = sb.runRepro(["home", "export", "--format", "json",
          "--target", "x86_64-linux"], host = host)
        checkpoint host & ": " & target.stderr
        require target.exitCode == 0
        let system = parseJson(target.stdout)["evaluation"]["system"]
        check system == expectedSystem(host)
        evaluations[host] = system
        if system["mode"].getStr notin modes:
          modes.add system["mode"].getStr
      check modes.len == 3
      let snapshot = sb.root / "export.json"
      writeFile(snapshot, exported.stdout)
      check sb.runRepro(["home", "export", "--check", snapshot],
        host = "rt-full").exitCode == 0
      sb.writeProfileFile("home.nim", homeProfile(Registry.replace(
        "activities: [web, backup]", "activities: [web]")))
      let stale = sb.runRepro(["home", "export", "--check", snapshot],
        host = "rt-full")
      checkpoint stale.stdout & stale.stderr
      check stale.exitCode == 1
      check "intent.hostSystems.rt-block.activities" in stale.stderr
      sb.writeProfileFile("home.nim", homeProfile(Registry))

      # 2. Macro -> RBPI -> planner, on a Debian base.
      sb.writeProfileFile("system.nim", SystemProfile)
      let stateDir = sb.root / "infra-state"
      createDir(stateDir)
      let env = [baseEnv("debian-13"),
                 ("REPROBUILD_ACTION_CACHE_ROOT", sb.root / "action-cache")]
      for (host, selection) in [
          ("rt-addon", "default"),
          ("rt-block", "default, web, backup"),
          ("rt-inline", "default, monitoring")]:
        let plan = sb.runRepro(["infra", "plan", "--state-dir", stateDir,
          "--profile", sb.profileDir / "system.nim", "--host", host],
          host = "", extraEnv = env)
        checkpoint host & ": " & plan.stdout & plan.stderr
        check plan.exitCode == 0
        check ("host " & host & ": system managed here in add-on mode " &
          "(system activities: " & selection & ")") in plan.stdout
        check "realised add-on-debian" in plan.stdout
      for host in ["rt-elsewhere", "rt-nopointer"]:
        let plan = sb.runRepro(["infra", "plan", "--state-dir", stateDir,
          "--profile", sb.profileDir / "system.nim", "--host", host],
          host = "", extraEnv = env)
        checkpoint host & ": " & plan.stdout & plan.stderr
        check plan.exitCode == 1
        check ("refusing host " & host & ": its system is managed " &
          "elsewhere") in plan.stderr
      # The `full` block form plans its selection on a ReproOS base, in full
      # (and is a mode mismatch on Debian: `t_addon_mode_mismatch_is_refused`).
      block:
        let plan = sb.runRepro(["infra", "plan", "--state-dir", stateDir,
          "--profile", sb.profileDir / "system.nim", "--host", "rt-fullblock"],
          host = "", extraEnv = [baseEnv("reproos"),
            ("REPROBUILD_ACTION_CACHE_ROOT", sb.root / "action-cache")])
        checkpoint "rt-fullblock: " & plan.stdout & plan.stderr
        check plan.exitCode == 0
        check "host rt-fullblock: system managed here (system activities: " &
          "default, web)" in plan.stdout
        check "system  : activities default, web; realised full" in plan.stdout

      # 3. Export -> Nix reader, from the export alone.
      let nixAnswers = nixEvalJson("""
        args:
        let
          lib = """ & nixLibExpr() & """;
          doc = builtins.fromJSON (builtins.readFile args.snapshot);
        in
        builtins.listToAttrs (map (host: {
          name = host;
          value = {
            hsm = lib.hostSystemManagement { document = doc; inherit host; };
            evaluation = (lib.evaluateExport doc "x86_64-linux" host).system;
          };
        }) args.hosts)
        """, %*{"snapshot": snapshot, "hosts": Hosts})
      for host in Hosts:
        var want = evaluations[host].copy()
        check nixAnswers[host]["evaluation"] == want
        want["host"] = %host
        check nixAnswers[host]["hsm"] == want

      # 4. A schema-4 export is refused by the Nix reader.
      var schema4Shape = doc.copy()
      schema4Shape["schemaVersion"] = %4
      schema4Shape["intent"].delete("hostSystems")
      schema4Shape["intent"]["systemManagedElsewhere"] = %*{
        "rt-elsewhere": {"managedBy": "example-org/rt"},
        "rt-nopointer": {"managedBy": nil}}
      schema4Shape["intent"]["hosts"].delete("rt-fullblock")
      schema4Shape["intent"]["hosts"].delete("rt-fullshort")
      var relabelled = doc.copy()
      relabelled["schemaVersion"] = %4
      for (name, bad) in [("schema4-shape", schema4Shape),
                          ("relabelled", relabelled)]:
        let path = sb.root / (name & ".json")
        writeFile(path, $bad)
        let refused = nixEvalJson("""
          args:
          let
            lib = """ & nixLibExpr() & """;
            doc = builtins.fromJSON (builtins.readFile args.snapshot);
            tries = map (host: {
              hsm = (builtins.tryEval (builtins.deepSeq
                (lib.hostSystemManagement { document = doc; inherit host; })
                true)).success;
              read = (builtins.tryEval (builtins.deepSeq
                (lib.readIntent { snapshot = args.snapshot; inherit host;
                                  system = "x86_64-linux"; })
                true)).success;
            }) args.hosts;
          in
          tries
          """, %*{"snapshot": path, "hosts": Hosts})
        checkpoint name & ": " & $refused
        for r in refused:
          check r["hsm"].getBool == false
          check r["read"].getBool == false

      # 5. Malformed values are refused at compile time, naming the host.
      for (bad, expected, parserPhrase) in [
          ("""
    "rt-bad":
      system: {mode: addOn, activities: []}
""", "the activity list is empty", "the activity list is empty"),
          ("""
    "rt-bad":
      system: {mode: addOn, activities: [default]}
""", "`default` is always enabled", "`default` is always enabled"),
          ("""
    "rt-bad":
      system: {activities: [web]}
""", "the block form needs `mode: addOn`", "the block form needs `mode: addOn`"),
          ("""
    "rt-bad":
      system:
        mode: nixos
        activities: [web]
""", "unknown mode `nixos`", "unknown mode `nixos`"),
          ("""
    "rt-bad":
      system: {mode: managedElsewhere, activities: [web]}
""", "`managedElsewhere` selects no system activities",
     "`managedElsewhere` selects no system activities"),
          ("""
    "rt-bad":
      system: {mode: addOn}
""", "the block form needs `activities: [...]`",
     "the block form needs `activities: [...]`"),
          ("""
    "rt-bad":
      system: {mode: full, activities: []}
""", "the activity list is empty", "the activity list is empty"),
          ("""
    "rt-bad":
      system: {mode: full}
""", "the block form needs `activities: [...]`",
     "the block form needs `activities: [...]`"),
          ("""
    "rt-bad":
      system: addOn("x")
""", "unknown `system:` value",
     "as the `system:` value of hosts entry \"rt-bad\"")]:
        sb.writeProfileFile("home.nim", homeProfile(bad))
        let r = sb.runRepro(["home", "export", "--format", "json"],
          host = "rt-bad")
        checkpoint "refusal case:\n" & bad & "\n" & r.stdout & r.stderr
        check r.exitCode != 0
        check expected in (r.stdout & r.stderr)
        check "rt-bad" in (r.stdout & r.stderr)
        # The text parser refuses it too, with the same reason (the shared
        # `host_system` vocabulary), through the structural editor's load.
        let edited = sb.runRepro(["home", "set", "a6rtnosuchpackage.key",
          "v", "--no-apply"], host = "rt-bad")
        checkpoint "home set: " & edited.stdout & edited.stderr
        check edited.exitCode != 0
        check parserPhrase in (edited.stdout & edited.stderr)
        check "rt-bad" in (edited.stdout & edited.stderr)
