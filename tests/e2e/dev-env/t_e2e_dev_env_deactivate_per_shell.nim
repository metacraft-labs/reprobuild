## M75 — per-shell parity for the deactivation formatter.
##
## The round-trip test (``t_e2e_dev_env_deactivate_round_trip.nim``)
## binds the bash deactivation path end-to-end against a synthetic
## env table. This file holds the per-shell formatter unit checks
## that match each shell's quoting rules byte-for-byte against the
## activation formatter — i.e. ``formatDeactivate(manifest, skX)``
## undoes ``formatExportPlan(plan, skX)`` symbolically for fish /
## pwsh / nushell.
##
## These are pure-formatter assertions; no live shell needed.

import std/[json, tables, unittest]

import repro_cli_support/dev_env_shell_export
import repro_cli_support/dev_env_rollback_manifest

proc syntheticPlanWithMarkers(): ExportPlan =
  result = @[]
  result.add(ExportOp(kind: opSet, name: "FIXTURE_MODE", value: "dev"))
  result.add(ExportOp(kind: opPrependPath, pathName: "PATH",
    segment: "/proj/tools/bin", separator: ":"))
  result.appendReproActiveManifestMarker("/tmp/m75.rollback.json")
  result.appendReproAppliedMarker("deadbeef")

proc preEnvWithFixture(): PreActivationEnv =
  result = initPreActivationEnv()
  result.table["PATH"] = "/usr/bin:/bin"
  # FIXTURE_MODE intentionally absent — was_set=false on rollback.

suite "e2e_dev_env_deactivate_per_shell":
  test "bash_deactivation_unset_then_restore_then_unset_markers":
    let plan = syntheticPlanWithMarkers()
    let script = formatExportPlan(plan, skBash)
    let manifest = buildRollbackManifest(plan, preEnvWithFixture(),
      "deadbeef", script, skBash)
    let deact = formatDeactivate(manifest, skBash)
    # Reverse-order expectation:
    #   1. unset __REPRO_APPLIED                  (marker)
    #   2. unset __REPRO_ACTIVE_MANIFEST          (marker)
    #   3. export PATH='/usr/bin:/bin'            (restore previous)
    #   4. unset FIXTURE_MODE                     (was_set=false)
    let expected =
      "unset __REPRO_APPLIED\n" &
      "unset __REPRO_ACTIVE_MANIFEST\n" &
      "export PATH='/usr/bin:/bin'\n" &
      "unset FIXTURE_MODE\n"
    check deact == expected

  test "fish_deactivation_uses_set_e_and_set_gx":
    let plan = syntheticPlanWithMarkers()
    let script = formatExportPlan(plan, skFish)
    let manifest = buildRollbackManifest(plan, preEnvWithFixture(),
      "deadbeef", script, skFish)
    let deact = formatDeactivate(manifest, skFish)
    let expected =
      "set -e __REPRO_APPLIED\n" &
      "set -e __REPRO_ACTIVE_MANIFEST\n" &
      "set -gx PATH '/usr/bin:/bin'\n" &
      "set -e FIXTURE_MODE\n"
    check deact == expected

  test "pwsh_deactivation_uses_remove_item_and_envcolon":
    let plan = syntheticPlanWithMarkers()
    let script = formatExportPlan(plan, skPwsh)
    let manifest = buildRollbackManifest(plan, preEnvWithFixture(),
      "deadbeef", script, skPwsh)
    let deact = formatDeactivate(manifest, skPwsh)
    let expected =
      "Remove-Item Env:__REPRO_APPLIED -ErrorAction SilentlyContinue\n" &
      "Remove-Item Env:__REPRO_ACTIVE_MANIFEST -ErrorAction SilentlyContinue\n" &
      "$env:PATH = '/usr/bin:/bin'\n" &
      "Remove-Item Env:FIXTURE_MODE -ErrorAction SilentlyContinue\n"
    check deact == expected

  test "nushell_deactivation_groups_load_env_with_trailing_hides":
    let plan = syntheticPlanWithMarkers()
    let script = formatExportPlan(plan, skNushell)
    let manifest = buildRollbackManifest(plan, preEnvWithFixture(),
      "deadbeef", script, skNushell)
    let deact = formatDeactivate(manifest, skNushell)
    # Reverse order: markers first (-> hide-env), then PATH
    # (was_set=true -> goes into load-env block), then FIXTURE_MODE
    # (was_set=false -> hide-env trailer).
    # load-env { PATH: '/usr/bin:/bin' }
    # hide-env __REPRO_APPLIED
    # hide-env __REPRO_ACTIVE_MANIFEST
    # hide-env FIXTURE_MODE
    let expected =
      "load-env {\n" &
      "  PATH: '/usr/bin:/bin'\n" &
      "}\n" &
      "hide-env __REPRO_APPLIED\n" &
      "hide-env __REPRO_ACTIVE_MANIFEST\n" &
      "hide-env FIXTURE_MODE\n"
    check deact == expected

  test "zsh_deactivation_matches_bash_byte_for_byte":
    let plan = syntheticPlanWithMarkers()
    let scriptBash = formatExportPlan(plan, skBash)
    let scriptZsh = formatExportPlan(plan, skZsh)
    let mBash = buildRollbackManifest(plan, preEnvWithFixture(),
      "deadbeef", scriptBash, skBash)
    let mZsh = buildRollbackManifest(plan, preEnvWithFixture(),
      "deadbeef", scriptZsh, skZsh)
    check formatDeactivate(mBash, skBash) == formatDeactivate(mZsh, skZsh)

  test "manifest_json_roundtrip_preserves_all_fields":
    let plan = syntheticPlanWithMarkers()
    let script = formatExportPlan(plan, skBash)
    let m1 = buildRollbackManifest(plan, preEnvWithFixture(),
      "deadbeef", script, skBash)
    let encoded = $m1.toJson()
    let m2 = fromJson(parseJson(encoded))
    check m2.artifact == m1.artifact
    check m2.activationScriptHash == m1.activationScriptHash
    check m2.activationShell == m1.activationShell
    check m2.vars.len == m1.vars.len
    for i in 0 ..< m1.vars.len:
      check m2.vars[i].name == m1.vars[i].name
      check m2.vars[i].op == m1.vars[i].op
      check m2.vars[i].value == m1.vars[i].value
      check m2.vars[i].segment == m1.vars[i].segment
      check m2.vars[i].separator == m1.vars[i].separator
      check m2.vars[i].previous == m1.vars[i].previous
      check m2.vars[i].wasSet == m1.vars[i].wasSet

  test "hash_is_deterministic_across_recomputations":
    let script = "export FOO='bar'\nexport BAZ='qux'\n"
    let h1 = computeActivationScriptHash(script)
    let h2 = computeActivationScriptHash(script)
    let h3 = computeActivationScriptHash(script)
    check h1 == h2
    check h2 == h3
    check h1.len == 16
    # Hex chars only.
    for ch in h1:
      check ch in {'0'..'9', 'a'..'f'}
