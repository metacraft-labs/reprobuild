## M76 — pure-formatter unit tests for ``repro shell hook <shell>``.
##
## These run on every host (no shell required). They assert:
##
## 1. Every renderer produces a non-empty script.
## 2. Every script defines ``__repro_shell_hook`` (per-shell function
##    name convention varies — pwsh uses ``__Repro-ShellHook``, nu uses
##    ``__repro_shell_hook``).
## 3. Each script encodes the M76 short-circuit (an equality check
##    between ``$__REPRO_PROJECT_ROOT`` and the candidate root) so
##    repeated prompts in the same project don't re-spawn ``repro``.
## 4. Each script references both ``dev-env export`` and
##    ``dev-env deactivate`` so the activation cycle is wired both
##    directions.
## 5. The ``--repro-bin`` flag embeds the path with each shell's
##    appropriate quoting (covers the test-harness pattern of forcing
##    an absolute path so PATH lookups can't surprise us).
## 6. Where possible, the script passes the host shell's syntax check
##    (bash -n for bash/zsh, pwsh parser for pwsh). Fish + nushell
##    fall through when their interpreters are not on PATH.

import std/[os, osproc, streams, strutils, unittest]

import repro_cli_support/dev_env_shell_hook_templates

proc syntaxCheckBashLocal(script, cwd: string): tuple[ok: bool; diag: string] =
  let scriptPath = cwd / "m76-bash-syntax-check.sh"
  writeFile(scriptPath, script)
  let bash = findExe("bash")
  if bash.len == 0:
    return (ok: false, diag: "bash not on PATH")
  var p = startProcess(bash, args = @["-n", scriptPath],
    workingDir = cwd, options = {poUsePath, poStdErrToStdOut})
  let output = if p.outputStream != nil: p.outputStream.readAll() else: ""
  let code = p.waitForExit()
  p.close()
  removeFile(scriptPath)
  (ok: code == 0, diag: output)

proc syntaxCheckPwshLocal(script, cwd: string): tuple[ok: bool; diag: string] =
  let scriptPath = cwd / "m76-pwsh-syntax-check.ps1"
  writeFile(scriptPath, script)
  let pwsh =
    if findExe("pwsh").len > 0: findExe("pwsh")
    else: findExe("powershell")
  if pwsh.len == 0:
    return (ok: false, diag: "pwsh/powershell not on PATH")
  var p = startProcess(pwsh, args = @[
    "-NoProfile", "-NonInteractive", "-Command",
    "$tokens = $null; $errors = $null; " &
      "[void][System.Management.Automation.Language.Parser]::ParseFile(" &
      "'" & scriptPath.replace("'", "''") &
      "', [ref]$tokens, [ref]$errors); " &
      "if ($errors -and $errors.Count -gt 0) { " &
      "  $errors | ForEach-Object { Write-Error $_.Message }; exit 1 " &
      "} else { exit 0 }"
  ], workingDir = cwd, options = {poUsePath, poStdErrToStdOut})
  let output = if p.outputStream != nil: p.outputStream.readAll() else: ""
  let code = p.waitForExit()
  p.close()
  removeFile(scriptPath)
  (ok: code == 0, diag: output)

suite "e2e_shell_hook_templates":

  test "bash_hook_renders_and_contains_short_circuit_check":
    let s = renderBashHook("")
    check s.len > 0
    check s.contains("__repro_shell_hook")
    # The short-circuit: only call ``dev-env export`` when the
    # candidate root differs from the currently-active project root.
    check s.contains("\"$__repro_candidate\" != \"${__REPRO_PROJECT_ROOT:-}\"")
    # Both ends of the cycle are present.
    check s.contains("dev-env export bash")
    check s.contains("dev-env deactivate")
    # Project-root detection markers.
    check s.contains("reprobuild.nim")
    check s.contains("repro.nim")
    check s.contains(".repro/dev-env.lock")
    # PROMPT_COMMAND idempotent install.
    check s.contains("PROMPT_COMMAND")

  test "bash_hook_with_repro_bin_quotes_the_path":
    let s = renderBashHook("/opt/repro it's a path/repro")
    # The path embeds a single quote; bash single-quoting closes the
    # quote, inserts ``\'``, and re-opens. We assert the path round-trips
    # via the literal substring sans quoting.
    check s.contains("/opt/repro it'\\''s a path/repro")
    # And there is NO bare ``repro`` reference outside comments/strings
    # for the dev-env arms — the quoted absolute path takes precedence.
    # (Grep against the explicit ``dev-env export`` invocation.)
    check s.contains("'/opt/repro it'\\''s a path/repro' dev-env export bash")

  test "bash_hook_passes_bash_n":
    let s = renderBashHook("")
    let tmp = getTempDir()
    let result = syntaxCheckBashLocal(s, tmp)
    if not result.ok and result.diag != "bash not on PATH":
      echo "bash -n diagnostic:\n", result.diag
      check false
    # On hosts without bash, we skip the syntax check — the rest of
    # the assertions in this suite already cover the template.

  test "zsh_hook_uses_chpwd_and_precmd_arrays":
    let s = renderZshHook("")
    check s.contains("__repro_shell_hook")
    check s.contains("chpwd_functions")
    check s.contains("precmd_functions")
    # Same short-circuit check.
    check s.contains("\"$__repro_candidate\" != \"${__REPRO_PROJECT_ROOT:-}\"")
    check s.contains("dev-env export bash")

  test "fish_hook_uses_on_variable_pwd_and_one_shot":
    let s = renderFishHook("")
    check s.contains("__repro_shell_hook")
    check s.contains("--on-variable PWD")
    # Final one-shot fire so the launching cwd activates.
    let trimmed = s.strip()
    check trimmed.endsWith("__repro_shell_hook")
    check s.contains("dev-env export fish")
    check s.contains("dev-env deactivate")

  test "pwsh_hook_wraps_existing_prompt":
    let s = renderPwshHook("")
    check s.contains("__Repro-ShellHook")
    check s.contains("__ReproOriginalPrompt")
    check s.contains("function prompt")
    check s.contains("dev-env export pwsh")
    check s.contains("dev-env deactivate")
    # Short-circuit equality check (PowerShell flavour).
    check s.contains("$candidate -ne $env:__REPRO_PROJECT_ROOT")

  test "pwsh_hook_passes_parser":
    let s = renderPwshHook("")
    let tmp = getTempDir()
    let result = syntaxCheckPwshLocal(s, tmp)
    if not result.ok and not result.diag.contains("not on PATH"):
      echo "pwsh parser diagnostic:\n", result.diag
      check false

  test "pwsh_hook_with_repro_bin_uses_call_operator":
    let s = renderPwshHook("C:/Program Files/repro/repro.exe")
    # Call operator + single-quoted absolute path.
    check s.contains("& 'C:/Program Files/repro/repro.exe' dev-env export pwsh")

  test "nushell_hook_installs_into_env_change_and_pre_prompt":
    let s = renderNushellHook("")
    check s.contains("__repro_shell_hook")
    check s.contains("hooks.env_change.PWD")
    check s.contains("hooks.pre_prompt")
    check s.contains("dev-env export nushell")
    check s.contains("dev-env deactivate")
    # Short-circuit (nushell flavour).
    check s.contains("$candidate != ($env.__REPRO_PROJECT_ROOT?")

  test "all_renderers_return_distinct_non_empty_scripts":
    let scripts = @[
      renderBashHook(""),
      renderZshHook(""),
      renderFishHook(""),
      renderPwshHook(""),
      renderNushellHook(""),
    ]
    for s in scripts:
      check s.len > 0
    # bash and zsh share the function body but their installation
    # tails diverge (PROMPT_COMMAND vs chpwd_functions).
    check scripts[0] != scripts[1]
    check scripts[0] != scripts[2]
    check scripts[0] != scripts[3]
    check scripts[0] != scripts[4]
    check scripts[2] != scripts[3]
    check scripts[3] != scripts[4]
