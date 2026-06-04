## M74 — ``repro dev-env export pwsh``.
##
## PowerShell syntax: ``$env:NAME = ...`` for scalars,
## ``Remove-Item Env:NAME`` for unsets, and the prepend/append
## blocks combine the segment with the host's existing value via
## ``$env:NAME + sep + ...``. Quoting uses single-quoted PowerShell
## strings with literal ``'`` doubled per pwsh parser rules.

import std/[os, strutils, unittest]

import repro_test_support
import dev_env_export_helper

suite "e2e_dev_env_export_pwsh":
  test "formatter_empty_plan_emits_empty_output":
    check formatExportPlan(emptyPlan(), skPwsh) == ""

  test "formatter_synthetic_plan_emits_expected_pwsh":
    let expected =
      "$env:FIXTURE_MODE = 'dev'\n" &
      "$env:AUX_VALUE = 'alpha'\n" &
      "if ($env:PATH) {\n" &
      "  $env:PATH = '/proj/tools/bin' + ':' + $env:PATH\n" &
      "} else {\n" &
      "  $env:PATH = '/proj/tools/bin'\n" &
      "}\n" &
      "$env:__REPRO_APPLIED = 'deadbeef'\n"
    check formatExportPlan(syntheticPlan(), skPwsh) == expected

  test "formatter_doubles_embedded_single_quote_for_pwsh":
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "MSG", value: "it's a test"))
    let emitted = formatExportPlan(plan, skPwsh)
    check emitted == "$env:MSG = 'it''s a test'\n"

  when isFsSnoopSupported:
    test "e2e_repro_dev_env_export_pwsh_against_fixture":
      let c = prepareCase("repro-m74-export-pwsh")
      defer: removeDir(c.tempRoot)
      let outcome = runReproExport(c, "pwsh")
      if outcome.exitCode != 0:
        echo "stdout:\n", outcome.stdout
        echo "stderr:\n", outcome.stderr
      check outcome.exitCode == 0
      check outcome.stdout.len > 0
      check outcome.stdout.contains("$env:FIXTURE_MODE = 'dev'")
      check outcome.stdout.contains("$env:AUX_VALUE = 'alpha'")
      check outcome.stdout.contains("$env:PATH")
      check outcome.stdout.contains("tools/bin")
      check outcome.stdout.contains("__REPRO_APPLIED")

      if shellAvailable("pwsh") or shellAvailable("powershell"):
        let syntax = syntaxCheckPwsh(outcome.stdout, c.tempRoot)
        if not syntax.ok:
          echo "pwsh parse diagnostic:\n", syntax.diag
        check syntax.ok
