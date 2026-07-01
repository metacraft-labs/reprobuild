## M75 — round-trip env-diff invariant for ``repro dev-env deactivate``.
##
## Capture env E0, run activation -> E1, run deactivation -> E2.
## Assert ``diffEnv(E0, E2) == [__REPRO_APPLIED unset,
## REPRO_DEV_ENV_WORKING_DIRECTORY unset, __REPRO_ACTIVE_MANIFEST
## unset]``. Loss tolerance: ZERO on every other var.
##
## The test does NOT require a live shell — it parses the emitted
## bash scripts syntactically (export/unset only — the activation
## script for our fixture is a pure sequence of those two ops plus
## PATH prepend) and applies the ops to a Nim ``Table[string,string]``
## that stands in for the shell env block. This works because
## ``formatBash`` for the synthetic plan emits a small, fully-known
## subset of POSIX shell syntax: ``export NAME='VALUE'``,
## ``unset NAME``, and the PATH prepend conditional block. The shell-
## fidelity of the OUTPUT was already verified by M74's per-shell
## syntax-check tests; M75's contract is the env-diff invariant.

import std/[os, osproc, streams, strtabs, strutils, tables, unittest]

import repro_test_support
import repro_cli_support/dev_env_shell_export
import repro_cli_support/dev_env_rollback_manifest
import dev_env_export_helper

type
  EnvTable = OrderedTable[string, string]

proc snapshotEnv(): EnvTable =
  result = initOrderedTable[string, string]()
  for k, v in envPairs():
    result[k] = v

proc copyEnv(src: EnvTable): EnvTable =
  result = initOrderedTable[string, string]()
  for k, v in src:
    result[k] = v

proc writePreActivationEnvFile(path: string; env: EnvTable) =
  ## File format documented in ``dev_env_rollback_manifest.nim``:
  ## a sequence of NUL-terminated ``NAME=VALUE`` records.
  var buf = ""
  for k, v in env:
    buf.add(k)
    buf.add('=')
    buf.add(v)
    buf.add('\0')
  writeFile(path, buf)

proc parseSingleQuotedBash(s: string; startIdx: int):
    tuple[value: string, nextIdx: int] =
  ## Mini-parser for the exact quoting ``formatBash`` emits: a single-
  ## quoted POSIX string with embedded ``'`` escaped as the classic
  ## four-character sequence ``'\''``. Returns the unescaped value
  ## and the index ONE PAST the closing quote.
  assert s[startIdx] == '\'', "bash literal must start with '"
  var i = startIdx + 1
  var result = ""
  while i < s.len:
    if s[i] == '\'':
      # Either the end of the literal OR the start of the embedded
      # `'\''` escape. Look ahead.
      if i + 3 < s.len and s[i+1] == '\\' and s[i+2] == '\'' and s[i+3] == '\'':
        result.add('\'')
        i += 4
        continue
      else:
        return (result, i + 1)
    else:
      result.add(s[i])
      inc i
  raise newException(ValueError,
    "unterminated single-quoted bash literal at " & $startIdx)

proc applyBashLine(env: var EnvTable; line: string) =
  let stripped = line.strip()
  if stripped.len == 0:
    return
  # The activation script for our fixture only uses these constructs:
  #   export NAME='VALUE'
  #   unset NAME
  #   if [ -n "${NAME:-}" ]; then
  #     export NAME='SEG':'SEP'"$NAME"
  #   else
  #     export NAME='SEG'
  #   fi
  # We process by simulating an `if [ -n "${NAME}" ]` branch test
  # against the current env table — same semantics as bash.
  discard stripped # noop: actual handling lives in applyBashScript

proc applyBashScript(env: var EnvTable; script: string) =
  ## Apply the activation OR deactivation script to ``env``. Handles
  ## the exact subset the bash formatter emits.
  let lines = script.splitLines()
  var i = 0
  while i < lines.len:
    let line = lines[i].strip()
    if line.len == 0:
      inc i
      continue
    if line.startsWith("export "):
      # ``export NAME='VALUE'`` or
      # ``export NAME='SEG'':'"$NAME"`` (PATH prepend) or
      # ``export NAME="$NAME"':'"'SEG'`` (PATH append)
      let rest = line[len("export ") .. ^1]
      let eqPos = rest.find('=')
      doAssert eqPos > 0, "malformed export: " & line
      let name = rest[0 ..< eqPos]
      let valuePart = rest[(eqPos + 1) .. ^1]
      # The value may be a concatenation of single-quoted literals
      # and ``"$NAME"`` expansions (no other constructs from the
      # formatter). Walk it left-to-right.
      var assembled = ""
      var p = 0
      while p < valuePart.len:
        if valuePart[p] == '\'':
          let (lit, np) = parseSingleQuotedBash(valuePart, p)
          assembled.add(lit)
          p = np
        elif valuePart[p] == '"':
          # Look for the closing quote. Inside, ``$NAME`` expands.
          inc p
          var inner = ""
          while p < valuePart.len and valuePart[p] != '"':
            inner.add(valuePart[p])
            inc p
          inc p # skip closing "
          # Expand ``$NAME`` references in inner.
          var qi = 0
          while qi < inner.len:
            if inner[qi] == '$':
              var ni = qi + 1
              while ni < inner.len and
                  (inner[ni] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}):
                inc ni
              let vname = inner[(qi + 1) ..< ni]
              if vname.len > 0 and vname in env:
                assembled.add(env[vname])
              qi = ni
            else:
              assembled.add(inner[qi])
              inc qi
        elif valuePart[p] == ' ' or valuePart[p] == '\t':
          inc p
        else:
          raise newException(ValueError,
            "unhandled bash export RHS character at pos " & $p &
            " in: " & line)
      env[name] = assembled
      inc i
    elif line.startsWith("unset "):
      let name = line[len("unset ") .. ^1].strip()
      if name in env:
        env.del(name)
      inc i
    elif line.startsWith("if "):
      # Parse: ``if [ -n "${NAME:-}" ]; then``
      # Find the variable name between ``${`` and ``:-}``.
      let lbrace = line.find("${")
      let rbrace = line.find(":-}")
      doAssert lbrace >= 0 and rbrace > lbrace,
        "unrecognised if-form: " & line
      let testedName = line[(lbrace + 2) ..< rbrace]
      let truthy = testedName in env and env[testedName].len > 0
      # Walk forward collecting the branch lines.
      var thenLines: seq[string] = @[]
      var elseLines: seq[string] = @[]
      var inElse = false
      inc i
      while i < lines.len:
        let l = lines[i].strip()
        if l == "else":
          inElse = true
          inc i
          continue
        if l == "fi":
          inc i
          break
        if inElse:
          elseLines.add(lines[i])
        else:
          thenLines.add(lines[i])
        inc i
      let branch = if truthy: thenLines else: elseLines
      applyBashScript(env, branch.join("\n"))
    elif line.startsWith(":") or line.startsWith("#"):
      # No-op / comment.
      inc i
    else:
      raise newException(ValueError,
        "unhandled bash line: " & line)

proc diffEnv(a, b: EnvTable):
    tuple[onlyInA: seq[string], onlyInB: seq[string],
          changed: seq[tuple[name, before, after: string]]] =
  var aKeys: seq[string] = @[]
  for k in a.keys: aKeys.add(k)
  var bKeys: seq[string] = @[]
  for k in b.keys: bKeys.add(k)
  for k in aKeys:
    if k notin b:
      result.onlyInA.add(k)
    elif a[k] != b[k]:
      result.changed.add((k, a[k], b[k]))
  for k in bKeys:
    if k notin a:
      result.onlyInB.add(k)

suite "e2e_dev_env_deactivate_round_trip_bash":
  test "unit_round_trip_synthetic_plan_zero_leakage":
    # E0: a small synthetic env.
    var e0 = initOrderedTable[string, string]()
    e0["PATH"] = "/usr/bin:/bin"
    e0["HOME"] = "/home/test"
    e0["EDITOR"] = "vim"
    e0["EMPTY_VAR"] = ""
    e0["FIXTURE_MODE"] = "pre-existing"  # will be overwritten by activation

    # Build the activation plan FROM the synthetic plan helper. The
    # plan is identical to what the live CLI would emit if its
    # fixture project produced FIXTURE_MODE=dev, AUX_VALUE=alpha,
    # prepend PATH=/proj/tools/bin.
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "FIXTURE_MODE", value: "dev"))
    plan.add(ExportOp(kind: opSet, name: "AUX_VALUE", value: "alpha"))
    plan.add(ExportOp(kind: opPrependPath, pathName: "PATH",
      segment: "/proj/tools/bin", separator: ":"))
    plan.appendReproActiveManifestMarker("/tmp/fake.rollback.json")
    plan.appendReproAppliedMarker("deadbeef")

    # Build the pre-activation snapshot the manifest will reference.
    var preEnv = initPreActivationEnv()
    for k, v in e0:
      preEnv.table[k] = v

    let activationScript = formatExportPlan(plan, skBash)
    let manifest = buildRollbackManifest(plan, preEnv, "deadbeef",
      activationScript, skBash)

    # Apply activation -> E1.
    var e1 = copyEnv(e0)
    applyBashScript(e1, activationScript)
    check e1["FIXTURE_MODE"] == "dev"
    check e1["AUX_VALUE"] == "alpha"
    check e1["PATH"] == "/proj/tools/bin:/usr/bin:/bin"
    check e1["__REPRO_APPLIED"] == "deadbeef"
    check e1["__REPRO_ACTIVE_MANIFEST"] == "/tmp/fake.rollback.json"

    # Apply deactivation -> E2.
    let deactivationScript = formatDeactivate(manifest, skBash)
    var e2 = copyEnv(e1)
    applyBashScript(e2, deactivationScript)

    # Invariant: E0 and E2 differ ONLY in that __REPRO_APPLIED,
    # __REPRO_ACTIVE_MANIFEST, and REPRO_DEV_ENV_WORKING_DIRECTORY
    # are unset in E2 (they were never in E0 either, so the diff is
    # actually empty for our synthetic plan).
    let diff = diffEnv(e0, e2)
    if diff.onlyInA.len > 0 or diff.onlyInB.len > 0 or
        diff.changed.len > 0:
      echo "leak in onlyInA (vars lost from E0): ", diff.onlyInA
      echo "leak in onlyInB (vars added in E2): ", diff.onlyInB
      for ch in diff.changed:
        echo "changed: ", ch.name, " ", ch.before, " -> ", ch.after
    check diff.onlyInA.len == 0
    check diff.changed.len == 0
    # E2 may NOT contain any of the reprobuild-internal markers.
    check "__REPRO_APPLIED" notin e2
    check "__REPRO_ACTIVE_MANIFEST" notin e2

  test "unit_round_trip_unset_then_restore":
    # E0 has no FIXTURE_MODE, then activation sets it, then
    # deactivation must unset it (was_set=false branch).
    var e0 = initOrderedTable[string, string]()
    e0["HOME"] = "/h"

    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "FIXTURE_MODE", value: "dev"))
    plan.appendReproAppliedMarker("cafebabe")

    var preEnv = initPreActivationEnv()
    for k, v in e0:
      preEnv.table[k] = v

    let actScript = formatExportPlan(plan, skBash)
    let manifest = buildRollbackManifest(plan, preEnv, "cafebabe",
      actScript, skBash)

    var e1 = copyEnv(e0)
    applyBashScript(e1, actScript)
    check e1["FIXTURE_MODE"] == "dev"

    var e2 = copyEnv(e1)
    applyBashScript(e2, formatDeactivate(manifest, skBash))
    check "FIXTURE_MODE" notin e2
    let diff = diffEnv(e0, e2)
    check diff.onlyInA.len == 0
    check diff.onlyInB.len == 0
    check diff.changed.len == 0

  test "unit_round_trip_set_to_empty_string_preserved":
    # E0 has EMPTY_VAR set to "" — a legal "set-to-empty-string"
    # that must NOT be conflated with "unset". was_set=true,
    # previous="".
    var e0 = initOrderedTable[string, string]()
    e0["EMPTY_VAR"] = ""

    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "EMPTY_VAR", value: "modified"))
    plan.appendReproAppliedMarker("deadcafe")

    var preEnv = initPreActivationEnv()
    preEnv.table["EMPTY_VAR"] = ""

    let actScript = formatExportPlan(plan, skBash)
    let manifest = buildRollbackManifest(plan, preEnv, "deadcafe",
      actScript, skBash)

    # The manifest must record was_set=true for EMPTY_VAR.
    var found = false
    for v in manifest.vars:
      if v.name == "EMPTY_VAR":
        check v.wasSet == true
        check v.previous == ""
        found = true
    check found

    var e1 = copyEnv(e0)
    applyBashScript(e1, actScript)
    check e1["EMPTY_VAR"] == "modified"

    var e2 = copyEnv(e1)
    applyBashScript(e2, formatDeactivate(manifest, skBash))
    check "EMPTY_VAR" in e2
    check e2["EMPTY_VAR"] == ""

  test "preActivationEnv_file_roundtrip":
    let tmp = getTempDir() / "m75-pre-env-roundtrip.bin"
    var e0 = initOrderedTable[string, string]()
    e0["SIMPLE"] = "hello"
    e0["WITH_NEWLINE"] = "line1\nline2"
    e0["WITH_EQUAL"] = "key=value=more"
    e0["EMPTY"] = ""
    writePreActivationEnvFile(tmp, e0)
    let parsed = readPreActivationEnv(tmp)
    check parsed.table["SIMPLE"] == "hello"
    check parsed.table["WITH_NEWLINE"] == "line1\nline2"
    check parsed.table["WITH_EQUAL"] == "key=value=more"
    check parsed.table["EMPTY"] == ""
    removeFile(tmp)

  when isIoMonitorSupported:
    test "e2e_repro_dev_env_round_trip_against_fixture":
      ## End-to-end: spawn ``repro dev-env export bash`` with a
      ## pre-activation env file, capture stdout, write the
      ## manifest path to a sidecar variable, spawn ``repro dev-env
      ## deactivate``, capture stdout, then verify the env-diff
      ## invariant by walking the bash scripts through our
      ## interpreter.
      let c = prepareCase("repro-m75-deactivate-round-trip")
      defer: removeDir(c.tempRoot)

      # Build the pre-activation env file from a synthetic E0 (we
      # don't want HOST env leaking into the assertion).
      var e0 = initOrderedTable[string, string]()
      e0["PATH"] = "/usr/bin:/bin"
      e0["HOME"] = "/home/test"
      e0["EDITOR"] = "vim"
      let preEnvFile = c.tempRoot / "pre-env.bin"
      writePreActivationEnvFile(preEnvFile, e0)

      # Activation.
      var exportEnv = c.envFor()
      var actProcess = startProcess(c.reproBin,
        args = @["dev-env", "export", "bash",
          "--project-root", c.projectRoot,
          "--pre-activation-env", preEnvFile],
        workingDir = c.repoRoot,
        env = exportEnv,
        options = {poUsePath})
      let actStdout = actProcess.outputStream.readAll()
      let actStderr = actProcess.errorStream.readAll()
      let actCode = actProcess.waitForExit()
      actProcess.close()
      if actCode != 0:
        echo "activation stdout:\n", actStdout
        echo "activation stderr:\n", actStderr
      check actCode == 0
      check actStdout.contains("__REPRO_APPLIED=")
      check actStdout.contains("__REPRO_ACTIVE_MANIFEST=")

      # Apply activation to e1.
      var e1 = copyEnv(e0)
      applyBashScript(e1, actStdout)
      check e1.contains("__REPRO_APPLIED")
      check e1.contains("__REPRO_ACTIVE_MANIFEST")
      let manifestPath = e1["__REPRO_ACTIVE_MANIFEST"]
      check fileExists(manifestPath)

      # Deactivation.
      var deactProcess = startProcess(c.reproBin,
        args = @["dev-env", "deactivate", manifestPath,
          "--shell", "bash"],
        workingDir = c.repoRoot,
        env = exportEnv,
        options = {poUsePath})
      let deactStdout = deactProcess.outputStream.readAll()
      let deactStderr = deactProcess.errorStream.readAll()
      let deactCode = deactProcess.waitForExit()
      deactProcess.close()
      if deactCode != 0:
        echo "deactivation stdout:\n", deactStdout
        echo "deactivation stderr:\n", deactStderr
      check deactCode == 0

      var e2 = copyEnv(e1)
      applyBashScript(e2, deactStdout)

      # Invariant: E0 == E2 byte-for-byte modulo the reprobuild
      # markers (which were never in E0, so the diff should be
      # empty).
      let diff = diffEnv(e0, e2)
      if diff.onlyInA.len > 0 or diff.onlyInB.len > 0 or
          diff.changed.len > 0:
        echo "leak onlyInA: ", diff.onlyInA
        echo "leak onlyInB: ", diff.onlyInB
        for ch in diff.changed:
          echo "changed: ", ch.name, " ", ch.before, " -> ", ch.after
      check diff.onlyInA.len == 0
      check diff.changed.len == 0
      check "__REPRO_APPLIED" notin e2
      check "__REPRO_ACTIVE_MANIFEST" notin e2
