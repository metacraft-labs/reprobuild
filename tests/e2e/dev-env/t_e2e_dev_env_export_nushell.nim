## M74 — ``repro dev-env export nushell``.
##
## Nushell cannot evaluate a string as code at run time, so the export is
## a NUON list of operation records (``{op: 'set' | 'unset' | 'prepend' |
## 'append', ...}``) that the hook reads with ``from nuon`` and applies in
## its own scope. The hook's behaviour is covered by
## ``t_e2e_shell_hook_nushell_activates``.

from repro_core/process_streams import drainStream
import std/[os, osproc, streams, strutils, unittest]

import repro_test_support
import dev_env_export_helper

suite "e2e_dev_env_export_nushell":
  test "formatter_empty_plan_emits_empty_output":
    check formatExportPlan(emptyPlan(), skNushell) == "[]\n"

  test "formatter_synthetic_plan_emits_expected_nushell":
    let expected =
      "[\n" &
      "  {op: 'set', name: 'FIXTURE_MODE', value: 'dev'}\n" &
      "  {op: 'set', name: 'AUX_VALUE', value: 'alpha'}\n" &
      "  {op: 'prepend', name: 'PATH', segment: '/proj/tools/bin', separator: ':'}\n" &
      "  {op: 'set', name: '__REPRO_APPLIED', value: 'deadbeef'}\n" &
      "]\n"
    check formatExportPlan(syntheticPlan(), skNushell) == expected

  test "formatter_falls_back_to_double_quotes_for_embedded_single_quote":
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "MSG", value: "it's a test"))
    let emitted = formatExportPlan(plan, skNushell)
    check emitted == "[\n  {op: 'set', name: 'MSG', value: \"it's a test\"}\n]\n"

  when isIoMonitorSupported:
    test "e2e_repro_dev_env_export_nushell_against_fixture":
      let c = prepareCase("repro-m74-export-nushell")
      defer: removeDir(c.tempRoot)
      let outcome = runReproExport(c, "nushell")
      if outcome.exitCode != 0:
        echo "stdout:\n", outcome.stdout
        echo "stderr:\n", outcome.stderr
      check outcome.exitCode == 0
      check outcome.stdout.len > 0
      check outcome.stdout.contains("name: 'FIXTURE_MODE', value: 'dev'")
      check outcome.stdout.contains("name: 'AUX_VALUE', value: 'alpha'")
      check outcome.stdout.contains("op: 'prepend'")
      check outcome.stdout.contains("tools/bin")
      check outcome.stdout.contains("__REPRO_APPLIED")
      # When ``nu`` is available, the output must parse as NUON.
      if shellAvailable("nu"):
        let nuBin = findExe("nu")
        let dataPath = c.tempRoot / "m74-nushell-export.nuon"
        writeFile(dataPath, outcome.stdout)
        var proc1 = startProcess(nuBin,
          args = @["--no-config-file", "--commands",
            "open --raw '" & dataPath & "' | from nuon | length"],
          workingDir = c.tempRoot,
          options = {poUsePath, poStdErrToStdOut})
        let diag = if proc1.outputStream != nil:
          drainStream(proc1.outputStream) else: ""
        let code = proc1.waitForExit()
        proc1.close()
        if code != 0:
          echo "nu diagnostic:\n", diag
        check code == 0
