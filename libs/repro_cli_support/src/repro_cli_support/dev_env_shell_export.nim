## M74 — ``repro dev-env export <shell>`` intermediate + per-shell
## formatters.
##
## The CLI dispatch arm (in ``repro_cli_support.nim``) resolves the
## project, walks the dev-env edge, reads the RBDE artifact, converts
## it into an ``ExportPlan`` (the spec-defined intermediate), and
## hands the plan to a per-shell formatter.
##
## The per-shell formatters here MUST be pure functions of
## ``ExportPlan`` — no I/O — so the unit-test surface in
## ``tests/e2e/dev-env/t_e2e_dev_env_export_<shell>.nim`` can pass
## synthetic plans and assert the output exactly.
##
## Quoting rules:
##
## * bash/zsh — POSIX single-quoting with literal-`'` handled via the
##   classic ``'\\''`` four-character escape.
## * fish — single-quoting with `\\` and `'` backslash-escaped.
## * nushell — single-quoting (no escapes legal in single quotes; we
##   pick double-quoted form if the value contains a literal `'`).
## * pwsh — single-quoting with literal-`'` doubled (`''`).

import std/[os, strutils]

import repro_dev_env_artifacts
import repro_provider_runtime

type
  ExportOpKind* = enum
    opSet
    opUnset
    opPrependPath
    opAppendPath
    opMarker

  ExportOp* = object
    case kind*: ExportOpKind
    of opSet:
      name*: string
      value*: string
    of opUnset:
      unsetName*: string
    of opPrependPath, opAppendPath:
      pathName*: string
      segment*: string
      separator*: string
    of opMarker:
      markerName*: string
      markerValue*: string

  ExportPlan* = seq[ExportOp]

  ShellKind* = enum
    skBash
    skZsh
    skFish
    skNushell
    skPwsh

  ExportPlanError* = object of CatchableError

proc raiseExportPlan(msg: string) {.noreturn.} =
  raise newException(ExportPlanError, msg)

proc parseShellKind*(value: string): ShellKind =
  ## Normalise the positional ``<shell>`` argument. Unknown shells
  ## throw — the dispatch arm converts the exception into an
  ## exit-code-2 + stderr diagnostic.
  case value.normalize()
  of "bash":
    skBash
  of "zsh":
    skZsh
  of "fish":
    skFish
  of "nushell", "nu":
    skNushell
  of "pwsh", "powershell", "ps", "ps1":
    skPwsh
  else:
    raiseExportPlan("unsupported shell: " & value &
      " (expected: bash|zsh|fish|nushell|pwsh)")

proc validEnvName(name: string): bool =
  if name.len == 0:
    return false
  if not (name[0] in {'A'..'Z', 'a'..'z', '_'}):
    return false
  for ch in name:
    if not (ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}):
      return false
  true

proc requireEnvName(name: string) =
  if not validEnvName(name):
    raiseExportPlan("invalid environment variable name: " & name)

# ---------------------------------------------------------------------
# RBDE artifact -> ExportPlan
# ---------------------------------------------------------------------

proc shellOpsToExportPlan*(ops: openArray[DevEnvShellOp]): ExportPlan =
  ## Convert shell ops to export ops.
  ##
  ## Split out of ``devEnvArtifactToExportPlan`` so ops that are NOT in
  ## the artifact can go through the identical conversion. The realized
  ## toolchain is the case: it is computed from the project interface at
  ## activation time rather than baked into the RBDE artifact, and the
  ## export arm has to emit it through the same path the artifact's own
  ## ops take, or the two would render differently.
  result = @[]
  for op in ops:
    let sep =
      if op.separator.len > 0: op.separator
      else: $PathSep
    case op.kind
    of deskSetEnv, deskSetPathList:
      result.add(ExportOp(kind: opSet, name: op.name, value: op.value))
    of deskUnsetEnv:
      result.add(ExportOp(kind: opUnset, unsetName: op.name))
    of deskPrependPath:
      result.add(ExportOp(kind: opPrependPath,
        pathName: op.name, segment: op.value, separator: sep))
    of deskAppendPath:
      result.add(ExportOp(kind: opAppendPath,
        pathName: op.name, segment: op.value, separator: sep))
    of deskSetWorkingDirectory:
      # M74 emits the working-directory request as a regular env var
      # so the prompt-hook side can pick it up; an actual ``cd`` in
      # the activation script would surprise the user.
      result.add(ExportOp(kind: opSet,
        name: "REPRO_DEV_ENV_WORKING_DIRECTORY", value: op.value))

# ---------------------------------------------------------------------
# Per-shell quoting helpers (pure)
# ---------------------------------------------------------------------

proc devEnvArtifactToExportPlan*(artifactPath: string): ExportPlan =
  ## Read the RBDE artifact, convert every shellOp to an ExportOp.
  ## The trailing ``opMarker`` for ``__REPRO_APPLIED`` is appended by
  ## the dispatch arm (which knows the fingerprint), not here.
  shellOpsToExportPlan(readDevEnvArtifact(artifactPath).shellOps)

proc bashQuote(value: string): string =
  ## POSIX single-quote with the classic ``'\\''`` escape for embedded
  ## single quotes; bash and zsh share the same rule.
  result = "'"
  for ch in value:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

proc fishQuote(value: string): string =
  result = "'"
  for ch in value:
    case ch
    of '\'': result.add("\\'")
    of '\\': result.add("\\\\")
    else: result.add(ch)
  result.add("'")

proc pwshQuote(value: string): string =
  "'" & value.replace("'", "''") & "'"

proc nuQuote(value: string): string =
  ## Nushell single quotes are literal — no escapes. If the value
  ## contains a literal `'`, fall back to double-quoted form with
  ## backslash escaping (`\\` and `\"`).
  if not value.contains('\''):
    return "'" & value & "'"
  result = "\""
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    else: result.add(ch)
  result.add("\"")

# ---------------------------------------------------------------------
# Per-shell formatters (pure functions of ExportPlan)
# ---------------------------------------------------------------------

proc formatBash(plan: ExportPlan): string =
  result = ""
  for op in plan:
    case op.kind
    of opSet:
      requireEnvName(op.name)
      result.add("export " & op.name & "=" & bashQuote(op.value) & "\n")
    of opUnset:
      requireEnvName(op.unsetName)
      result.add("unset " & op.unsetName & "\n")
    of opPrependPath:
      requireEnvName(op.pathName)
      result.add("if [ -n \"${" & op.pathName & ":-}\" ]; then\n")
      result.add("  export " & op.pathName & "=" & bashQuote(op.segment) &
        bashQuote(op.separator) & "\"$" & op.pathName & "\"\n")
      result.add("else\n")
      result.add("  export " & op.pathName & "=" & bashQuote(op.segment) & "\n")
      result.add("fi\n")
    of opAppendPath:
      requireEnvName(op.pathName)
      result.add("if [ -n \"${" & op.pathName & ":-}\" ]; then\n")
      result.add("  export " & op.pathName & "=\"$" & op.pathName & "\"" &
        bashQuote(op.separator) & bashQuote(op.segment) & "\n")
      result.add("else\n")
      result.add("  export " & op.pathName & "=" & bashQuote(op.segment) & "\n")
      result.add("fi\n")
    of opMarker:
      requireEnvName(op.markerName)
      result.add("export " & op.markerName & "=" &
        bashQuote(op.markerValue) & "\n")

proc formatFish(plan: ExportPlan): string =
  result = ""
  for op in plan:
    case op.kind
    of opSet:
      requireEnvName(op.name)
      result.add("set -gx " & op.name & " " & fishQuote(op.value) & "\n")
    of opUnset:
      requireEnvName(op.unsetName)
      result.add("set -e " & op.unsetName & "\n")
    of opPrependPath:
      requireEnvName(op.pathName)
      if op.pathName == "PATH":
        # fish keeps PATH as a list. ``fish_add_path`` is the canonical
        # prepend; ``--path`` gives universal/global scope per
        # interaction.
        result.add("fish_add_path --path --prepend " &
          fishQuote(op.segment) & "\n")
      else:
        result.add("if set -q " & op.pathName & "\n")
        result.add("  set -gx " & op.pathName & " " & fishQuote(op.segment) &
          " $" & op.pathName & "\n")
        result.add("else\n")
        result.add("  set -gx " & op.pathName & " " &
          fishQuote(op.segment) & "\n")
        result.add("end\n")
    of opAppendPath:
      requireEnvName(op.pathName)
      if op.pathName == "PATH":
        result.add("fish_add_path --path --append " &
          fishQuote(op.segment) & "\n")
      else:
        result.add("if set -q " & op.pathName & "\n")
        result.add("  set -gx " & op.pathName & " $" & op.pathName & " " &
          fishQuote(op.segment) & "\n")
        result.add("else\n")
        result.add("  set -gx " & op.pathName & " " &
          fishQuote(op.segment) & "\n")
        result.add("end\n")
    of opMarker:
      requireEnvName(op.markerName)
      result.add("set -gx " & op.markerName & " " &
        fishQuote(op.markerValue) & "\n")

proc nuonRecord*(fields: openArray[(string, string)]): string =
  ## One Nushell record literal, ``{key: 'value', ...}``, every value a
  ## string. Keys are fixed identifiers chosen by the emitters, never data.
  result = "{"
  for i, (key, value) in fields:
    if i > 0:
      result.add(", ")
    result.add(key & ": " & nuQuote(value))
  result.add("}")

proc nuonList*(records: seq[string]): string =
  ## The Nushell list literal the nushell hook reads with ``from nuon``;
  ## one record per line, ``[]`` when there is nothing to apply.
  if records.len == 0:
    return "[]\n"
  result = "[\n"
  for record in records:
    result.add("  " & record & "\n")
  result.add("]\n")

proc formatNushell(plan: ExportPlan): string =
  ## Nushell cannot evaluate a string as code at run time (``source`` and
  ## ``eval``-style commands are parse-time only), so unlike the other
  ## shells the activation is DATA, not a script: a NUON list of operation
  ## records, in plan order, which the hook (``renderNushellHook``) reads
  ## with ``from nuon`` and applies in its own scope. Record shapes:
  ##   ``{op: 'set', name, value}``
  ##   ``{op: 'unset', name}``
  ##   ``{op: 'prepend' | 'append', name, segment, separator}``
  ##   ``{op: 'warn', message}``
  ## PATH-like variables are joined by the hook, which knows whether the
  ## shell holds them as a list (the nushell default) or a string.
  var records: seq[string] = @[]
  for op in plan:
    case op.kind
    of opSet:
      requireEnvName(op.name)
      records.add(nuonRecord({"op": "set", "name": op.name,
        "value": op.value}))
    of opMarker:
      requireEnvName(op.markerName)
      records.add(nuonRecord({"op": "set", "name": op.markerName,
        "value": op.markerValue}))
    of opUnset:
      requireEnvName(op.unsetName)
      records.add(nuonRecord({"op": "unset", "name": op.unsetName}))
    of opPrependPath:
      requireEnvName(op.pathName)
      records.add(nuonRecord({"op": "prepend", "name": op.pathName,
        "segment": op.segment, "separator": op.separator}))
    of opAppendPath:
      requireEnvName(op.pathName)
      records.add(nuonRecord({"op": "append", "name": op.pathName,
        "segment": op.segment, "separator": op.separator}))
  nuonList(records)

proc formatPwsh(plan: ExportPlan): string =
  result = ""
  for op in plan:
    case op.kind
    of opSet:
      requireEnvName(op.name)
      result.add("$env:" & op.name & " = " & pwshQuote(op.value) & "\n")
    of opUnset:
      requireEnvName(op.unsetName)
      result.add("Remove-Item Env:" & op.unsetName &
        " -ErrorAction SilentlyContinue\n")
    of opPrependPath:
      requireEnvName(op.pathName)
      result.add("if ($env:" & op.pathName & ") {\n")
      result.add("  $env:" & op.pathName & " = " & pwshQuote(op.segment) &
        " + " & pwshQuote(op.separator) & " + $env:" & op.pathName & "\n")
      result.add("} else {\n")
      result.add("  $env:" & op.pathName & " = " &
        pwshQuote(op.segment) & "\n")
      result.add("}\n")
    of opAppendPath:
      requireEnvName(op.pathName)
      result.add("if ($env:" & op.pathName & ") {\n")
      result.add("  $env:" & op.pathName & " = $env:" & op.pathName & " + " &
        pwshQuote(op.separator) & " + " & pwshQuote(op.segment) & "\n")
      result.add("} else {\n")
      result.add("  $env:" & op.pathName & " = " &
        pwshQuote(op.segment) & "\n")
      result.add("}\n")
    of opMarker:
      requireEnvName(op.markerName)
      result.add("$env:" & op.markerName & " = " &
        pwshQuote(op.markerValue) & "\n")

proc formatExportPlan*(plan: ExportPlan; shell: ShellKind): string =
  ## Pure dispatch table. No I/O.
  case shell
  of skBash, skZsh:
    formatBash(plan)
  of skFish:
    formatFish(plan)
  of skNushell:
    formatNushell(plan)
  of skPwsh:
    formatPwsh(plan)

# ---------------------------------------------------------------------
# Marker helper — keeps the constant name in one place for both the
# CLI dispatch arm and the milestone test.
# ---------------------------------------------------------------------

const
  ReproAppliedMarkerName* = "__REPRO_APPLIED"
  ReproActiveManifestMarkerName* = "__REPRO_ACTIVE_MANIFEST"

proc appendReproAppliedMarker*(plan: var ExportPlan; fingerprint: string) =
  plan.add(ExportOp(kind: opMarker,
    markerName: ReproAppliedMarkerName,
    markerValue: fingerprint))

proc appendReproActiveManifestMarker*(plan: var ExportPlan;
                                      manifestPath: string) =
  ## M75 — record the rollback manifest path so the per-prompt hook
  ## (M76) knows which manifest to feed ``repro dev-env deactivate``
  ## on cd-out. Treated as a marker so the rollback emitter unsets it
  ## (rather than restoring a pre-activation value).
  plan.add(ExportOp(kind: opMarker,
    markerName: ReproActiveManifestMarkerName,
    markerValue: manifestPath))

# ---------------------------------------------------------------------
# M77 — fast-path no-op emitter.
#
# When the cache-key fast path in ``repro dev-env export`` matches the
# already-applied fingerprint we still emit SOMETHING — the shell hook
# unconditionally ``eval``s our stdout, so we have to produce a script
# that parses cleanly under each shell and does nothing observable. The
# message text is informational; the leading ``:`` (bash/zsh) or ``#``
# (fish/nushell/pwsh) is the load-bearing part.
# ---------------------------------------------------------------------

proc emitFastPathNoOpScript*(shell: ShellKind): string =
  ## Per-shell no-op activation script emitted on a cache-key fast-path
  ## hit. Asserted in ``tests/e2e/dev-env/t_e2e_shell_hook_noop_latency.nim``.
  case shell
  of skBash, skZsh:
    ": # repro shell hook: no-op (cache key unchanged)\n"
  of skFish:
    "# repro shell hook: no-op (cache key unchanged)\n"
  of skNushell:
    "[]\n"  # an empty NUON operation list; see ``formatNushell``
  of skPwsh:
    "# repro shell hook: no-op (cache key unchanged)\n"
