## A fake io-monitor driver that records nothing and runs the action as is.
##
## WHY THIS EXISTS. An action declared ``dgAutomaticMonitor`` FAILS when no
## monitor driver is wired (Monitor-Hook-Shim.md: "injection failure MUST
## fail the monitored action or make it non-cacheable"). Tests that exercise
## something else about such an action -- its environment, its scheduling --
## therefore wire this passthrough as ``BuildEngineConfig.monitorCliPath``:
## it copies a pre-built, empty-but-valid evidence file to the ``--depfile``
## path the engine names (so the engine's evidence read succeeds with a
## complete, zero-record dependency set) and then runs the real action argv
## unchanged, with the environment it inherited.
##
## THE ARGV CONTRACT IT PARSES. The engine wraps a monitored action as
##
##   <monitorCli> [monitorCliArgs…] --depfile <capture>
##                --interest <tokens> --evidence <scope> -- <action argv…>
##
## (``repro_build_engine``'s wrapping site, which builds exactly that list).
## The flags between the driver and ``--`` have grown over time, so both
## spellings below find ``--depfile`` by NAME and the payload by the FIRST
## ``--`` instead of by position. A positional Windows copy (``%4 %5 …``)
## outlived the addition of ``--interest`` and ``--evidence`` and executed
## the interest token as a program, failing every monitored action it
## wrapped on Windows (reprobuild-pm
## ``issues/2026-11-16-windows-tool-identity-env-plumbing-probes-fail-on-eli-pc.md``).
## A driver that finds no ``--`` refuses with exit 2 rather than running
## its own flags as a command.

import std/os

proc writePassthroughMonitorCli*(dir, evidenceTemplate: string): string =
  ## Write the passthrough driver into ``dir`` (which must exist) and return
  ## its path. ``evidenceTemplate`` is the file copied to ``--depfile``;
  ## callers produce it with io-mon's own encoder (``encodeCanonical(@[])``)
  ## so this module stays independent of the evidence wire format.
  when defined(windows):
    result = dir / "passthrough-monitor.cmd"
    # ``shift`` does not change ``%*``, so the payload is taken from the raw
    # argument text instead of being rebuilt from ``%1``…: cmd also splits
    # arguments at ``,``, ``;`` and ``=`` (the interest token is a comma
    # list), and rebuilding would rewrite such a payload. ``%all:* -- =%``
    # deletes everything up to and including the first `` -- ``, which is
    # the separator the parse loop has just confirmed is present.
    # ``endlocal & %rest%`` expands ``rest`` before ``endlocal`` runs, so the
    # payload starts without this script's variables in its environment.
    writeFile(result,
      "@echo off\r\n" &
      "setlocal\r\n" &
      "set \"depfile=\"\r\n" &
      ":parse\r\n" &
      "if [%1]==[] goto noseparator\r\n" &
      "if \"%~1\"==\"--\" goto run\r\n" &
      "if \"%~1\"==\"--depfile\" (\r\n" &
      "  set \"depfile=%~2\"\r\n" &
      "  shift\r\n" &
      ")\r\n" &
      "shift\r\n" &
      "goto parse\r\n" &
      ":noseparator\r\n" &
      "echo passthrough-monitor: no -- separates the action argv 1>&2\r\n" &
      "exit /b 2\r\n" &
      ":run\r\n" &
      "if defined depfile (\r\n" &
      "  for %%I in (\"%depfile%\") do if not exist \"%%~dpI\" mkdir \"%%~dpI\"\r\n" &
      "  copy /Y \"" & evidenceTemplate & "\" \"%depfile%\" >nul\r\n" &
      ")\r\n" &
      "set \"all=%*\"\r\n" &
      "set \"rest=%all:* -- =%\"\r\n" &
      "endlocal & %rest%\r\n")
  else:
    result = dir / "passthrough-monitor.sh"
    writeFile(result,
      "#!/bin/sh\n" &
      "depfile=\"\"\n" &
      "separated=0\n" &
      "while [ \"$#\" -gt 0 ]; do\n" &
      "  case \"$1\" in\n" &
      "    --depfile) depfile=\"$2\"; shift 2;;\n" &
      "    --) shift; separated=1; break;;\n" &
      "    *) shift;;\n" &
      "  esac\n" &
      "done\n" &
      "if [ \"$separated\" != 1 ]; then\n" &
      "  echo 'passthrough-monitor: no -- separates the action argv' >&2\n" &
      "  exit 2\n" &
      "fi\n" &
      "if [ -n \"$depfile\" ]; then\n" &
      "  mkdir -p \"$(dirname \"$depfile\")\"\n" &
      "  cp \"" & evidenceTemplate & "\" \"$depfile\"\n" &
      "fi\n" &
      "exec \"$@\"\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
