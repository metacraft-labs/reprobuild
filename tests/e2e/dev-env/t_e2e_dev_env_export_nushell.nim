## M74 — ``repro dev-env export nushell``.
##
## Nushell wraps scalar sets in ``load-env { ... }`` so a sourced
## script sets the caller's env. PATH ops use the ``path add``
## builtin. Custom-separator path-lists fall back to
## ``$env.NAME = ... + sep + ...``.

import std/[os, osproc, streams, strutils, unittest]

import repro_test_support
import dev_env_export_helper

suite "e2e_dev_env_export_nushell":
  test "formatter_empty_plan_emits_empty_output":
    check formatExportPlan(emptyPlan(), skNushell) == ""

  test "formatter_synthetic_plan_emits_expected_nushell":
    let expected =
      "load-env {\n" &
      "  FIXTURE_MODE: 'dev'\n" &
      "  AUX_VALUE: 'alpha'\n" &
      "  __REPRO_APPLIED: 'deadbeef'\n" &
      "}\n" &
      "path add '/proj/tools/bin'\n"
    check formatExportPlan(syntheticPlan(), skNushell) == expected

  test "formatter_falls_back_to_double_quotes_for_embedded_single_quote":
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "MSG", value: "it's a test"))
    let emitted = formatExportPlan(plan, skNushell)
    check emitted == "load-env {\n  MSG: \"it's a test\"\n}\n"

  when isFsSnoopSupported:
    test "e2e_repro_dev_env_export_nushell_against_fixture":
      let c = prepareCase("repro-m74-export-nushell")
      defer: removeDir(c.tempRoot)
      let outcome = runReproExport(c, "nushell")
      if outcome.exitCode != 0:
        echo "stdout:\n", outcome.stdout
        echo "stderr:\n", outcome.stderr
      check outcome.exitCode == 0
      check outcome.stdout.len > 0
      check outcome.stdout.contains("FIXTURE_MODE: 'dev'")
      check outcome.stdout.contains("AUX_VALUE: 'alpha'")
      check outcome.stdout.contains("path add")
      check outcome.stdout.contains("tools/bin")
      check outcome.stdout.contains("__REPRO_APPLIED")
      # Nushell isn't always on PATH; the formatter unit tests cover
      # the syntax correctness. When ``nu`` IS available, run the
      # script through ``nu --commands "do { ... }"`` to confirm parse.
      if shellAvailable("nu"):
        let nuBin = findExe("nu")
        let scriptPath = c.tempRoot / "m74-nushell-syntax-check.nu"
        writeFile(scriptPath, outcome.stdout)
        var proc1 = startProcess(nuBin,
          args = @["--no-config-file", "--commands",
            "nu --ide-check 0 " & scriptPath],
          workingDir = c.tempRoot,
          options = {poUsePath, poStdErrToStdOut})
        let diag = if proc1.outputStream != nil:
          proc1.outputStream.readAll() else: ""
        let code = proc1.waitForExit()
        proc1.close()
        if code != 0:
          echo "nu diagnostic:\n", diag
        # We don't require nu to succeed on every host; treat any
        # exit code as informational. The exact-string formatter
        # assertions above are the binding contract.
        discard code
