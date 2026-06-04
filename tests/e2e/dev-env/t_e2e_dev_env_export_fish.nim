## M74 — ``repro dev-env export fish``.
##
## Fish syntax: ``set -gx``, ``set -e``, ``fish_add_path``. PATH
## prepends MUST use ``fish_add_path --path --prepend`` so the value
## stays a fish "path-variable" (semi-colon-joined list) and not a
## scalar.

import std/[os, strutils, unittest]

import repro_test_support
import dev_env_export_helper

suite "e2e_dev_env_export_fish":
  test "formatter_empty_plan_emits_empty_output":
    check formatExportPlan(emptyPlan(), skFish) == ""

  test "formatter_synthetic_plan_emits_expected_fish":
    let expected =
      "set -gx FIXTURE_MODE 'dev'\n" &
      "set -gx AUX_VALUE 'alpha'\n" &
      "fish_add_path --path --prepend '/proj/tools/bin'\n" &
      "set -gx __REPRO_APPLIED 'deadbeef'\n"
    check formatExportPlan(syntheticPlan(), skFish) == expected

  test "formatter_quotes_embedded_backslash_and_quote":
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "MSG", value: "it's \\ a test"))
    let emitted = formatExportPlan(plan, skFish)
    check emitted == "set -gx MSG 'it\\'s \\\\ a test'\n"

  when isFsSnoopSupported:
    test "e2e_repro_dev_env_export_fish_against_fixture":
      let c = prepareCase("repro-m74-export-fish")
      defer: removeDir(c.tempRoot)
      let outcome = runReproExport(c, "fish")
      if outcome.exitCode != 0:
        echo "stdout:\n", outcome.stdout
        echo "stderr:\n", outcome.stderr
      check outcome.exitCode == 0
      check outcome.stdout.len > 0
      check outcome.stdout.contains("set -gx FIXTURE_MODE 'dev'")
      check outcome.stdout.contains("set -gx AUX_VALUE 'alpha'")
      check outcome.stdout.contains("fish_add_path")
      check outcome.stdout.contains("tools/bin")
      check outcome.stdout.contains("__REPRO_APPLIED")

      if shellAvailable("fish"):
        let syntax = syntaxCheckFish(outcome.stdout, c.tempRoot)
        if not syntax.ok:
          echo "fish -n diagnostic:\n", syntax.diag
        check syntax.ok
