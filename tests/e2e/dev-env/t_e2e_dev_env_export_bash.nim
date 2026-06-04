## M74 — ``repro dev-env export bash``.
##
## Pure-formatter unit tests run unconditionally; the live end-to-end
## CLI test only runs when ``isFsSnoopSupported`` (the provider build
## edge needs the fs-snoop + monitor shim) and the test asserts the
## stdout passes ``bash -n`` AND contains the fixture's PATH segment,
## FIXTURE_MODE, AUX_VALUE, and the ``__REPRO_APPLIED`` marker.

import std/[os, strutils, unittest]

import repro_test_support
import dev_env_export_helper

suite "e2e_dev_env_export_bash":
  test "formatter_empty_plan_emits_empty_output":
    check formatExportPlan(emptyPlan(), skBash) == ""

  test "formatter_synthetic_plan_emits_expected_bash":
    let expected =
      "export FIXTURE_MODE='dev'\n" &
      "export AUX_VALUE='alpha'\n" &
      "if [ -n \"${PATH:-}\" ]; then\n" &
      "  export PATH='/proj/tools/bin'':'\"$PATH\"\n" &
      "else\n" &
      "  export PATH='/proj/tools/bin'\n" &
      "fi\n" &
      "export __REPRO_APPLIED='deadbeef'\n"
    check formatExportPlan(syntheticPlan(), skBash) == expected

  test "formatter_quotes_embedded_single_quotes_safely":
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "MSG", value: "it's a test"))
    let emitted = formatExportPlan(plan, skBash)
    check emitted == "export MSG='it'\\''s a test'\n"

  when isFsSnoopSupported:
    test "e2e_repro_dev_env_export_bash_against_fixture":
      let c = prepareCase("repro-m74-export-bash")
      defer: removeDir(c.tempRoot)
      let outcome = runReproExport(c, "bash")
      if outcome.exitCode != 0:
        echo "stdout:\n", outcome.stdout
        echo "stderr:\n", outcome.stderr
      check outcome.exitCode == 0
      check outcome.stdout.len > 0
      check outcome.stdout.contains("export FIXTURE_MODE='dev'")
      check outcome.stdout.contains("export AUX_VALUE='alpha'")
      check outcome.stdout.contains("tools/bin")
      check outcome.stdout.contains("__REPRO_APPLIED=")

      # If bash is on PATH, run a parse-only sanity check; otherwise
      # skip but DON'T fail the test — the formatter unit tests above
      # still guard the syntax.
      if shellAvailable("bash"):
        let syntax = syntaxCheckBash(outcome.stdout, c.tempRoot)
        if not syntax.ok:
          echo "bash -n diagnostic:\n", syntax.diag
        check syntax.ok
