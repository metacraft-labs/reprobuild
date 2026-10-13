## An export whose intent a compile-time `when defined(...)` decided is
## marked per target platform, and evaluating it for a platform it does not
## describe is refused with a diagnostic.
##
## `e2e_export_refuses_compile_time_dependent_intent`: the fixture decides
## platform content at COMPILE time in two places the `profile` macro sees
## differently — a `when defined(macosx):` inside `resources:`, and a
## `when defined(windows)` inside a helper proc in a sibling module, which
## the macro never sees (only the platform probe's evaluation can). Exported
## on this (Linux) host:
##
## * `platforms` marks both darwin and both windows platforms `differs` and
##   both linux platforms `same` — the probe evaluated the profile under each
##   platform's definitions and compared;
## * positive control: `--target x86_64-windows` and `--target
##   aarch64-darwin` exit 3, print no document, and the diagnostic names the
##   target, the compiling platform and the compile-time cause; the library
##   entry point (`evaluateHomeExport`) raises `HomeExportRefused` for the
##   same document;
## * negative control: `--target aarch64-linux` (a different platform the
##   profile does not depend on) and the compiling platform are evaluated
##   (exit 0, `evaluation` present), and a profile using only runtime
##   predicates is evaluated for every platform
##   (`t_e2e_export_describes_other_platform_resources`).
##
## `e2e_export_refuses_intent_the_probe_cannot_evaluate`: a profile whose
## intent calls into C (`importc`) cannot be evaluated in Nim's compile-time
## VM. Every platform is then `unevaluated` with the reason recorded in
## `provenance.compile.probe`, every other platform is refused ("could not
## evaluate"), and the compiling platform is still evaluated — the probe
## failing makes the document less useful, never wrong. A second fixture
## evaluates in the VM but to a different intent than the native run
## (`when nimvm`): the probe is then not trusted for any platform, even
## though every check succeeded and agreed with every other.
##
## `e2e_export_sees_per_platform_config_defines`: the profile's own
## `config.nims` defines a symbol, and a string define's value, only
## `when defined(macosx)`; the profile's `resources:` test them with
## `when defined(...)` / `when <strdefine> == ...`. The probe must evaluate
## the configuration under each target (as a compile there would), so both
## darwin platforms are `differs` and the others `same` (positive control:
## windows and linux are evaluated, not merely unevaluated). This is the
## regression gate for a probe that skipped the configuration files and
## passed the host's resolved defines instead, which reported `same` for
## darwin.
##
## `e2e_runtime_and_compile_time_conditions_do_not_mix`: a `when` chain in
## `resources:` with one runtime predicate and one `defined(...)` does not
## compile, and the diagnostic says why. An action edge (`inlineExecCall`),
## which carries no guard, under a runtime predicate is refused when the
## profile runs instead of being applied on every host.
##
## Falsifying mutation (performed when this gate was written): make
## `refusalReason` accept every platform (return ""). The windows and darwin
## targets then exit 0 and the gate goes red at the refusal checks.
##
## No mocks: real `build/bin/repro`, real Nim, real io-mon shim, real
## filesystem; the `nim` spy is a pass-through counter (harness header).

import repro_test_support/reasoned_skip

const PlatformSkipReason =
  "[platform N/A] t_e2e_export_refuses_compile_time_dependent_intent: the " &
  "nim spy and the stderr capture are POSIX shell, and the fixture's " &
  "expectations are written for a Linux compiling platform."

when not defined(linux):
  import std/unittest

  suite "repro home export: compile-time platform dependence":
    test "e2e_export_refuses_compile_time_dependent_intent":
      skip(PlatformSkipReason)
    test "e2e_export_refuses_intent_the_probe_cannot_evaluate":
      skip(PlatformSkipReason)
    test "e2e_export_sees_per_platform_config_defines":
      skip(PlatformSkipReason)
    test "e2e_runtime_and_compile_time_conditions_do_not_mix":
      skip(PlatformSkipReason)
else:
  import std/[json, os, strutils, unittest]

  import repro_profile_compile
  import repro_cli_support/home_export

  import ./profile_compile_edge_harness

  const DependentProfile = """
import repro_profile
import ./modules/os_tools

profile "gm3Dependent":
  activity default:
    ripgrep
    osTools()

  resources:
    fsUserFile(hostFile = "~/.gm3-common", content = "c\n", address = "common")
    when defined(macosx):
      fsUserFile(hostFile = "~/.gm3-mac", content = "m\n", address = "macOnly")
"""

  const OsToolsModule = """
import repro_profile

proc osTools*(): seq[ActivityElement] =
  # Compile-time platform selection in a helper: invisible to the `profile`
  # macro, decided by whichever platform compiles the profile.
  when defined(windows):
    @[package "gm3-winget"]
  else:
    @[]
"""

  const ForeignCallProfile = """
import repro_profile

proc c_getpid(): cint {.importc: "getpid", header: "<unistd.h>".}

proc pidMarker(): string =
  if c_getpid() > 0: "running\n" else: "?\n"

profile "gm3ForeignCall":
  activity default:
    ripgrep

  resources:
    fsUserFile(hostFile = "~/.gm3-pid", content = pidMarker(), address = "pid")
"""

  const ConfigDefineProfile = """
import repro_profile

const gm3Flavor {.strdefine.} = "plain"

profile "gm3ConfigDefine":
  activity default:
    ripgrep

  resources:
    fsUserFile(hostFile = "~/.gm3-common", content = "c\n", address = "common")
    when defined(gm3MacSymbol):
      fsUserFile(hostFile = "~/.gm3-symbol", content = "s\n",
        address = "macSymbol")
    when gm3Flavor == "mac":
      fsUserFile(hostFile = "~/.gm3-flavor", content = "f\n",
        address = "macFlavor")
"""

  proc configDefineNims(): string =
    ## The profile's own config.nims. A profile directory that has one is
    ## not given the staged wrapper, so it includes reprobuild's itself, as
    ## such a profile must.
    "include \"" & (ProjectRoot / "config.nims").replace('\\', '/') &
      "\"\n" &
      "when defined(macosx):\n" &
      "  switch(\"define\", \"gm3MacSymbol\")\n" &
      "  switch(\"define\", \"gm3Flavor=mac\")\n" &
      "else:\n" &
      "  switch(\"define\", \"gm3Flavor=other\")\n"

  const VmDivergentProfile = """
import repro_profile

proc whereEvaluated(): string =
  when nimvm:
    "vm\n"
  else:
    "native\n"

profile "gm3VmDivergent":
  activity default:
    ripgrep

  resources:
    fsUserFile(hostFile = "~/.gm3-where", content = whereEvaluated(),
      address = "where")
"""

  const MixedChainProfile = """
import repro_profile

profile "gm3Mixed":
  activity default:
    ripgrep

  resources:
    when linux():
      fsUserFile(hostFile = "~/.a", content = "a\n", address = "a")
    elif defined(windows):
      fsUserFile(hostFile = "~/.b", content = "b\n", address = "b")
"""

  const GuardedActionEdgeProfile = """
import repro_profile

profile "gm3GuardedEdge":
  activity default:
    ripgrep

  resources:
    when linux():
      inlineExecCall(argv = @["true"], address = "gm3Edge")
"""

  proc exportDoc(sb: ProfileSandbox; extra: openArray[string] = []):
      (ReproRun, JsonNode) =
    let run = sb.runRepro(@["home", "export", "--host", "gm3-host"] & @extra,
      host = "")
    checkpoint("repro home export " & extra.join(" ") & ": exit " &
      $run.exitCode & "\nstderr:\n" & run.stderr)
    var doc: JsonNode = nil
    if run.exitCode == 0:
      doc = parseJson(run.stdout)
    (run, doc)

  suite "repro home export: compile-time platform dependence":

    test "e2e_export_refuses_compile_time_dependent_intent":
      require compilingPlatformSystem() in ["x86_64-linux", "aarch64-linux"]
      let sb = newProfileSandbox("gm3-dependent", DependentProfile)
      defer: sb.dispose()
      sb.writeProfileFile("modules/os_tools.nim", OsToolsModule)

      let (run, doc) = sb.exportDoc()
      require run.exitCode == 0
      checkpoint("platforms: " & $doc["platforms"] & "\nprobe: " &
        $doc["provenance"]["compile"]["probe"])
      check doc["provenance"]["compile"]["target"].getStr ==
        compilingPlatformSystem()
      for system in ["x86_64-linux", "aarch64-linux"]:
        check doc["platforms"][system].getStr == "same"
      for system in ["x86_64-darwin", "aarch64-darwin", "x86_64-windows",
                     "aarch64-windows"]:
        check doc["platforms"][system].getStr == "differs"
      # Vacuity: the compile-time branches really did decide this intent
      # for Linux -- neither platform-specific element is in it.
      check doc["intent"]["resources"].len == 1
      check not ($doc["intent"]).contains("gm3-winget")

      # Positive control: refused for platforms it does not describe.
      for system in ["x86_64-windows", "aarch64-darwin"]:
        let (refused, _) = sb.exportDoc(["--target", system])
        check refused.exitCode == 3
        check refused.stdout.len == 0
        check refused.stderr.contains("cannot evaluate this export for " &
          system)
        check refused.stderr.contains("compiled on " &
          compilingPlatformSystem())
        check refused.stderr.contains("when defined(...)")
        expect HomeExportRefused:
          discard evaluateHomeExport(doc, system)

      # Negative control: a platform the intent does not depend on, and the
      # compiling platform itself, are evaluated.
      for system in ["aarch64-linux", compilingPlatformSystem()]:
        let (accepted, evaluatedDoc) = sb.exportDoc(["--target", system])
        require accepted.exitCode == 0
        check evaluatedDoc["evaluation"]["target"].getStr == system
        check evaluatedDoc["evaluation"]["resources"].len == 1
        check evaluatedDoc["evaluation"] == evaluateHomeExport(doc, system)

    test "e2e_export_refuses_intent_the_probe_cannot_evaluate":
      let sb = newProfileSandbox("gm3-foreign", ForeignCallProfile)
      defer: sb.dispose()
      let (run, doc) = sb.exportDoc()
      require run.exitCode == 0
      checkpoint("platforms: " & $doc["platforms"] & "\nprobe: " &
        $doc["provenance"]["compile"]["probe"])
      # The native compile ran the C call; the intent is complete.
      check doc["intent"]["resources"][0]["fields"]["content"]["value"].getStr ==
        "running\n"
      for system in targetSystemNames():
        check doc["platforms"][system].getStr == "unevaluated"
        check doc["provenance"]["compile"]["probe"][system].getStr.len > 0
      let other =
        if compilingPlatformSystem() == "aarch64-linux": "x86_64-linux"
        else: "aarch64-linux"
      let (refused, _) = sb.exportDoc(["--target", other])
      check refused.exitCode == 3
      check refused.stderr.contains("could not evaluate the profile for " &
        other)
      let (own, ownDoc) = sb.exportDoc(["--target",
        compilingPlatformSystem()])
      require own.exitCode == 0
      check ownDoc["evaluation"]["resources"].len == 1

      # The VM evaluates, but not to what the native run produced: nothing
      # the probe says is used, though every platform agreed with the others.
      let vm = newProfileSandbox("gm3-vm-divergent", VmDivergentProfile)
      defer: vm.dispose()
      let (vmRun, vmDoc) = vm.exportDoc()
      require vmRun.exitCode == 0
      checkpoint("platforms: " & $vmDoc["platforms"] & "\nprobe: " &
        $vmDoc["provenance"]["compile"]["probe"])
      check vmDoc["intent"]["resources"][0]["fields"]["content"]["value"].getStr ==
        "native\n"
      for system in targetSystemNames():
        check vmDoc["platforms"][system].getStr == "unevaluated"
        check vmDoc["provenance"]["compile"]["probe"][system].getStr.contains(
          "differs from its native run")
      let (vmRefused, _) = vm.exportDoc(["--target", other])
      check vmRefused.exitCode == 3

    test "e2e_export_sees_per_platform_config_defines":
      require compilingPlatformSystem() in ["x86_64-linux", "aarch64-linux"]
      let sb = newProfileSandbox("gm3-config-define", ConfigDefineProfile)
      defer: sb.dispose()
      sb.writeProfileFile("config.nims", configDefineNims())
      let (run, doc) = sb.exportDoc()
      require run.exitCode == 0
      checkpoint("platforms: " & $doc["platforms"] & "\nprobe: " &
        $doc["provenance"]["compile"]["probe"])
      # Vacuity: on Linux neither darwin-only resource is declared.
      check doc["intent"]["resources"].len == 1
      for system in ["x86_64-darwin", "aarch64-darwin"]:
        check doc["platforms"][system].getStr == "differs"
      for system in ["x86_64-linux", "aarch64-linux", "x86_64-windows",
                     "aarch64-windows"]:
        check doc["platforms"][system].getStr == "same"
      let (refused, _) = sb.exportDoc(["--target", "aarch64-darwin"])
      check refused.exitCode == 3

    test "e2e_runtime_and_compile_time_conditions_do_not_mix":
      let sb = newProfileSandbox("gm3-mixed", MixedChainProfile)
      defer: sb.dispose()
      let (run, _) = sb.exportDoc()
      check run.exitCode == 1
      check run.stderr.contains("mixes runtime predicates")

      let edge = newProfileSandbox("gm3-guarded-edge",
        GuardedActionEdgeProfile)
      defer: edge.dispose()
      let (edgeRun, _) = edge.exportDoc()
      check edgeRun.exitCode == 1
      check edgeRun.stderr.contains("action edges carry no guard")
