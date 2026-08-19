## Bootstrap-And-Self-Build B0: develop-mode resolution carries runquotad.
##
## Asserts that when the engine inspects reprobuild's action graph with
## ``runquotad`` declared in ``uses:``, the path-mode tool inspection resolves
## a concrete ``runquotad`` executable. Older graph payloads exposed the bare
## selector in graph JSON; current payloads record it in
## ``toolInspectionPath``.
##
## Engine surface
## --------------
## We use ``./build/bin/repro graph --tool-provisioning=path --format=json`` to
## render the action graph as JSON, then load the graph's
## ``toolInspectionPath`` artifact and check for a resolved ``runquotad``
## profile.
##
## Note: ``--daemon=off`` is intentionally NOT passed here. The
## ``--daemon`` flag is a ``build``/``watch`` option, not a global
## option — the ``repro graph`` signature in ``repro --help`` does
## not list ``--daemon``. Passing it would trigger the CLI usage
## dump (exit 2) before any graph payload is rendered.
## ``--tool-provisioning`` must likewise be passed *after* the
## ``graph`` subcommand for the parser to bind it.
##
## No soft fallback
## ----------------
## ``repro graph`` must render a payload. There used to be two classifiers
## here — ``looksLikeCliRejection`` and ``looksLikeProvisioningFailure`` —
## that read the failure's own text and turned a non-zero exit into a skip
## when it mentioned tool resolution, ``libclingo``, ``PATH``, or looked like
## the CLI usage dump. Between them they absorbed nearly every way this
## invocation can fail, including a regression in the very flag placement
## the note above documents. This suite compiles and runs under
## ``nix develop``, where the toolchain and ``libclingo`` are present by
## construction, so a failure here is a fact about the engine and it fails
## the case.
##
## ``runquota`` is a declared workspace dependency. Resolve its source through
## the workspace-aware fixture helper so a linked reprobuild worktree reaches
## the same checkout as the primary workspace. A genuinely missing checkout is
## a hard, actionable fixture error rather than a skipped engine assertion.

import std/[json, os, osproc, strtabs, strutils, unittest]

import repro_test_support

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc graphMentionsRunquotad(payload: JsonNode;
                            runquotaCheckout: string): bool =
  ## Walk the JSON payload looking for any string that
  ##   * contains the substring "runquotad", AND
  ##   * is rooted in the local ``runquotaCheckout`` directory
  ##     (absolute or repo-relative ``../runquota/...`` form).
  ##
  ## We accept both shapes because the engine's graph output may
  ## normalise paths either way depending on the view.
  let absRoot = runquotaCheckout.absolutePath
  let absRootSlash = absRoot & "/"
  proc walk(node: JsonNode): bool =
    case node.kind
    of JString:
      let s = node.getStr("")
      if "runquotad" notin s:
        return false
      if s.startsWith(absRootSlash) or s == absRoot:
        return true
      if "../runquota/" in s or s.startsWith("../runquota/"):
        return true
      return false
    of JObject:
      for k, v in node:
        if walk(v):
          return true
      return false
    of JArray:
      for v in node:
        if walk(v):
          return true
      return false
    else:
      return false
  walk(payload)

proc graphMentionsRunquotadAtAll(payload: JsonNode): bool =
  ## Looser check used when the engine emits a graph that names
  ## ``runquotad`` but with non-path identifiers (e.g. tool selectors).
  ## A bare mention is enough to confirm the engine *saw* the use:
  ## entry; the path-root assertion above is the stricter form.
  proc walk(node: JsonNode): bool =
    case node.kind
    of JString:
      return "runquotad" in node.getStr("")
    of JObject:
      for k, v in node:
        if walk(v):
          return true
      return false
    of JArray:
      for v in node:
        if walk(v):
          return true
      return false
    else:
      return false
  walk(payload)

proc inspectionResolvesRunquotad(payload: JsonNode):
    tuple[found: bool; resolvedPath: string] =
  let inspectionPath = payload{"toolInspectionPath"}.getStr("")
  if inspectionPath.len == 0 or not fileExists(inspectionPath):
    return
  let inspection = parseFile(inspectionPath)
  for profile in inspection{"profiles"}:
    if profile{"executableName"}.getStr("") == "runquotad":
      return (true, profile{"resolvedExecutablePath"}.getStr(""))

suite "Bootstrap-And-Self-Build B0: develop-mode resolves runquotad":

  test "repro graph records a path-mode runquotad profile":
    let reprobuildRoot = findRepoRoot()
    let runquotaCheckout = requireRunQuotaSourceRoot(reprobuildRoot)
    let runquotad = requireBinary(runquotaCheckout / "build" / "bin" /
      addFileExt("runquotad", ExeExt), "runquota.apps.runquotad")
    let reproBin = reprobuildRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    else:
      # Per ``repro --help``: ``--daemon`` is a ``build``/``watch``
      # flag, NOT a global flag and NOT a ``graph`` flag. Passing
      # it here would dump the CLI usage and exit 2 before any
      # graph payload is rendered. Likewise, ``--tool-provisioning``
      # must follow the subcommand to be bound to it.
      let args = @[
        reproBin.quoteShell,
        "graph",
        "--tool-provisioning=path",
        "--format=json",
      ]
      let cmd = args.join(" ")
      checkpoint("running: " & cmd)
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        env[key] = value
      env["PATH"] = runquotad.parentDir & $PathSep &
        env.getOrDefault("PATH")
      let (output, exitCode) =
        execCmdEx(cmd, workingDir = reprobuildRoot, env = env)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
        check exitCode == 0
      else:
        # JSON payload may be preceded by progress lines; find the
        # first ``{`` character and parse from there.
        let braceIdx = output.find('{')
        if braceIdx < 0:
          checkpoint("no JSON object found in graph output")
          checkpoint(output)
          check false
        else:
          var payload: JsonNode = nil
          var parseError = ""
          try:
            payload = parseJson(output[braceIdx .. ^1])
          except JsonParsingError as err:
            parseError = err.msg
          if payload.isNil:
            checkpoint("could not parse graph JSON: " & parseError)
            checkpoint(output)
            check false
          else:
            let resolved = inspectionResolvesRunquotad(payload)
            checkpoint("tool inspection resolves runquotad: " &
              $resolved.found)
            checkpoint("runquotad resolved path: " & resolved.resolvedPath)
            if resolved.found:
              check resolved.resolvedPath.len > 0
            else:
              # Older graph payloads exposed the bare selector directly in
              # the graph JSON. Keep that as a compatibility fallback.
              let sawAny = graphMentionsRunquotadAtAll(payload)
              checkpoint("graph mentions runquotad: " & $sawAny)
              check sawAny

            let checkoutRoot = normalizedPath(runquotaCheckout)
            let sawLocalSource =
              if resolved.found:
                let resolvedPath = normalizedPath(resolved.resolvedPath)
                resolvedPath == checkoutRoot or
                  resolvedPath.startsWith(checkoutRoot & $DirSep)
              else:
                graphMentionsRunquotad(payload, runquotaCheckout)
            checkpoint("graph roots runquotad at workspace checkout: " &
              $sawLocalSource)
            check sawLocalSource
