## M74 — ``repro dev-env export zsh``.
##
## zsh and bash share the same POSIX-shell output, so the formatter
## tests assert identity with the bash formatter. The CLI test still
## hits the dispatch arm independently to confirm the zsh shell-kind
## flag routes through the same code path.

import std/[os, osproc, streams, strutils, unittest]

import repro_test_support
import dev_env_export_helper

suite "e2e_dev_env_export_zsh":
  test "formatter_empty_plan_emits_empty_output":
    check formatExportPlan(emptyPlan(), skZsh) == ""

  test "formatter_zsh_output_matches_bash_byte_for_byte":
    check formatExportPlan(syntheticPlan(), skZsh) ==
      formatExportPlan(syntheticPlan(), skBash)

  when isFsSnoopSupported:
    test "e2e_repro_dev_env_export_zsh_against_fixture":
      let c = prepareCase("repro-m74-export-zsh")
      defer: removeDir(c.tempRoot)
      let outcome = runReproExport(c, "zsh")
      if outcome.exitCode != 0:
        echo "stdout:\n", outcome.stdout
        echo "stderr:\n", outcome.stderr
      check outcome.exitCode == 0
      check outcome.stdout.len > 0
      check outcome.stdout.contains("export FIXTURE_MODE='dev'")
      check outcome.stdout.contains("export AUX_VALUE='alpha'")
      check outcome.stdout.contains("tools/bin")
      check outcome.stdout.contains("__REPRO_APPLIED=")

      # zsh's ``zsh -n`` accepts the POSIX subset we emit. If zsh isn't
      # installed (common on Windows runners), fall back to bash -n —
      # the output is plain POSIX.
      if shellAvailable("zsh"):
        let zshBin = findExe("zsh")
        let scriptPath = c.tempRoot / "m74-zsh-syntax-check.zsh"
        writeFile(scriptPath, outcome.stdout)
        var proc1 = startProcess(zshBin, args = @["-n", scriptPath],
          workingDir = c.tempRoot,
          options = {poUsePath, poStdErrToStdOut})
        let diag = if proc1.outputStream != nil:
          proc1.outputStream.readAll() else: ""
        let code = proc1.waitForExit()
        proc1.close()
        if code != 0:
          echo "zsh -n diagnostic:\n", diag
        check code == 0
      elif shellAvailable("bash"):
        let syntax = syntaxCheckBash(outcome.stdout, c.tempRoot)
        if not syntax.ok:
          echo "fallback bash -n diagnostic:\n", syntax.diag
        check syntax.ok
