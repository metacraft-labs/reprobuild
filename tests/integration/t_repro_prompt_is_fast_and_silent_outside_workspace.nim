## RA-26 — `repro prompt` ambient workspace-state segment.
##
## `repro prompt` is recomputed on EVERY shell render, so it must be (a)
## SILENT and exit 0 outside a workspace — safe to drop into any prompt with
## no guards — and (b) FAST: it reads only CHEAP CACHED workspace state
## (``.repo/workspace.toml``, the cached ``.repro/workspace/sync-report.json``,
## and the develop-overrides file), never fanning out a ``git`` subprocess per
## repo.
##
## This suite is hermetic + black-box: it builds and runs ``build/bin/repro``
## against fresh tempdirs only; nothing touches ``$HOME`` or any shared cache,
## and it spawns no git.
##
## Falsifiability of each assertion (confirmed by the implementor before
## landing — see the agent report):
##   * Silence: making ``repro prompt`` print outside a workspace fails the
##     empty-stdout assertion.
##   * Latency: adding an artificial per-repo sleep / live git fan-out pushes
##     wall time over ``MaxPromptMs`` and fails the budget assertion.
##   * Inside-segment: removing the cached-state read (so the segment is empty
##     inside a real workspace) fails the non-empty + JSON assertions.
##   * Init snippet: emitting nothing / not referencing ``repro prompt`` fails
##     the init assertions.

import std/[json, os, sequtils, strutils, tempfiles, times, unittest]

import repro_test_support

# ---- latency budget --------------------------------------------------------
#
# CLI/prompt.md requires the prompt to be "fast enough to run on every render".
# A naive implementation that shells out to ``git`` once per repo in even a
# small multi-repo workspace easily costs hundreds of milliseconds (process
# spawn + index scan per repo, ×N repos). The cached-state implementation here
# is a handful of small filesystem reads and one JSON parse — single-digit
# milliseconds of real work.
#
# We pick 750 ms as the per-invocation ceiling. That is:
#   * comfortably above process-spawn + Nim-runtime startup jitter on a loaded
#     CI box (so it does NOT flake), yet
#   * far BELOW the cost of a real per-repo git fan-out across several repos
#     (which the falsifiability check confirms blows the budget), so a
#     regression to live git observation would FAIL this test.
# We measure the BEST of several runs to discount one-off scheduler stalls.
const MaxPromptMs = 750.0
const PromptRuns = 5

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc runPrompt(reproBin: string; cwd: string; extra: seq[string] = @[]):
    tuple[res: CmdResult; ms: float] =
  ## Run ``repro prompt <extra...>`` in ``cwd`` and return the result plus the
  ## measured wall-clock time in milliseconds.
  let cmd = shellCommand(@[reproBin, "prompt"] & extra)
  let t0 = epochTime()
  let res = runShell(cmd, cwd = cwd)
  let elapsed = (epochTime() - t0) * 1000.0
  (res: res, ms: elapsed)

proc bestPromptMs(reproBin: string; cwd: string;
                  extra: seq[string] = @[]): float =
  ## Best (minimum) wall time across ``PromptRuns`` runs — discounts a single
  ## scheduler stall while still catching a systematically-slow implementation.
  result = MaxPromptMs * 1000.0
  for _ in 0 ..< PromptRuns:
    let m = runPrompt(reproBin, cwd, extra).ms
    if m < result:
      result = m

proc seedWorkspace(root: string) =
  ## A minimal initialized workspace: the RA-10 marker (``.repo/workspace.toml``
  ## with an active branch) plus a cached sync report recording three repos,
  ## one of which sits on a different branch (a drift signal). All cheap cached
  ## state — NO git repos are created.
  createDir(root / ".repo")
  writeFile(root / ".repo" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n" &
    "[workspace]\n" &
    "project = \"demo\"\n" &
    "branch = \"feat-x\"\n")
  createDir(root / ".repro" / "workspace")
  writeFile(root / ".repro" / "workspace" / "sync-report.json",
    """{ "repos": [
      {"name":"a","path":"a","branch":"feat-x"},
      {"name":"b","path":"b","branch":"other"},
      {"name":"c","path":"c","branch":"feat-x"}
    ] }""")

# ---- the suite -------------------------------------------------------------

suite "RA-26 — repro prompt is fast and silent outside a workspace":

  test "t_repro_prompt_is_fast_and_silent_outside_workspace":
    let reproBin = reproBinary()
    let scratch = createTempDir("repro-ra26-", "")
    defer: removeDir(scratch)

    # ========================================================================
    # Part 1 — OUTSIDE a workspace: silent + exit 0. A plain temp dir with no
    # ``.repo/`` anywhere above it. The prompt must print NOTHING so it is safe
    # to drop unconditionally into any shell prompt.
    # ========================================================================
    let plainDir = scratch / "not-a-workspace"
    createDir(plainDir)
    let outside = runPrompt(reproBin, plainDir)
    if outside.res.output.len != 0:
      checkpoint("expected empty stdout outside a workspace, got: " &
        outside.res.output)
    check outside.res.output.len == 0
    check outside.res.code == 0

    # ========================================================================
    # Part 2 — LATENCY BUDGET outside a workspace. The fast path (no workspace
    # marker found while ascending) must complete well under MaxPromptMs.
    # ========================================================================
    let outsideMs = bestPromptMs(reproBin, plainDir)
    if outsideMs >= MaxPromptMs:
      checkpoint("prompt too slow outside workspace: " & $outsideMs &
        " ms (budget " & $MaxPromptMs & " ms)")
    check outsideMs < MaxPromptMs

    # ========================================================================
    # Part 3 — INSIDE a workspace: a non-empty segment reflecting cached state,
    # also within the latency budget (it reads cached files, not live git).
    # ========================================================================
    let wsRoot = scratch / "workspace"
    createDir(wsRoot)
    seedWorkspace(wsRoot)

    let inside = runPrompt(reproBin, wsRoot)
    check inside.res.code == 0
    check inside.res.output.strip().len > 0
    # The segment reflects the cached workspace branch.
    check inside.res.output.contains("feat-x")

    # Reads from a SUBDIRECTORY still find the workspace (ascending marker
    # lookup), proving it is not a cwd-only check.
    let subDir = wsRoot / "deep" / "nested"
    createDir(subDir)
    let sub = runPrompt(reproBin, subDir)
    check sub.res.code == 0
    check sub.res.output.contains("feat-x")

    # Fast inside too — cached-state read, no per-repo git fan-out.
    let insideMs = bestPromptMs(reproBin, wsRoot)
    if insideMs >= MaxPromptMs:
      checkpoint("prompt too slow inside workspace: " & $insideMs &
        " ms (budget " & $MaxPromptMs & " ms)")
    check insideMs < MaxPromptMs

    # ========================================================================
    # Part 4 — ``--format json`` emits valid JSON carrying the cached facts.
    # ========================================================================
    let jsonRes = runPrompt(reproBin, wsRoot, @["--format", "json"]).res
    check jsonRes.code == 0
    var parsed: JsonNode
    try:
      parsed = parseJson(jsonRes.output.strip())
    except JsonParsingError:
      checkpoint("--format json did not emit valid JSON: " & jsonRes.output)
      fail()
    check parsed.kind == JObject
    check parsed["inWorkspace"].getBool()
    check parsed["branch"].getStr() == "feat-x"
    # Three repos in the cached sync report, one of them drifted (branch
    # "other" != workspace branch "feat-x").
    check parsed["repoCount"].getInt() == 3
    check parsed["driftRepos"].getInt() == 1

    # ========================================================================
    # Part 5 — ``repro prompt init <shell>`` prints a non-empty snippet that
    # references ``repro prompt`` and mutates nothing. Check two shells.
    # ========================================================================
    let snapBefore = walkDirRec(wsRoot).toSeq().len
    for shell in ["bash", "fish"]:
      let initRes = runShell(
        shellCommand(@[reproBin, "prompt", "init", shell]), cwd = wsRoot)
      check initRes.code == 0
      check initRes.output.strip().len > 0
      check initRes.output.contains("repro")
      check initRes.output.contains("prompt")
    # init only PRINTS a snippet — it must not create or remove any file.
    let snapAfter = walkDirRec(wsRoot).toSeq().len
    check snapAfter == snapBefore
