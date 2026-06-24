## t_no_runtime_compilation_in_tests — Test-Fixtures-In-Build-Graph M4
## regression guard.
##
## The Test-Fixtures-In-Build-Graph campaign (M1–M3) moved the test
## suite's *setup* compilation out of test-runtime code and into the
## reprobuild build graph: the ``repro`` CLI (``apps/repro/repro.nim``)
## and the monitor shim (now the io-mon sibling: ``io_mon/shim/*``)
## are now graph edges, compiled once / content-addressed / cached, and
## test-runtime code only *asserts* their presence via
## ``repro_test_support.requireBinary`` instead of shelling out to a
## compiler per test.
##
## This guard prevents that regression: it scans every test source under
## the discovery roots and FAILS if a test re-introduces a runtime
## ``nim c`` compile of one of the hoisted *setup* sources — i.e. the
## copy-pasted ``proc compileNim(... "apps/repro/repro.nim" ...)`` /
## ``proc compileRepro`` shell-outs M1 deleted, or the per-test
## ``prepareMonitorTools`` ``nim c --app:lib`` shim compile M2 deleted.
##
## ----------------------------------------------------------------------
## What is scanned
## ----------------------------------------------------------------------
## Every ``*.nim`` and ``*.sh`` file under the three test-discovery roots
## (mirroring ``scripts/generate_test_edges.nim``):
##
##   * ``tests/`` (recursive)
##   * ``libs/*/tests/`` (recursive)
##   * ``tools/*/tests/`` (recursive)
##
## (this guard file excludes itself, since it necessarily names the
## forbidden patterns in prose).
##
## For each file the guard looks, line by line (comment lines stripped),
## for a runtime compiler invocation:
##
##   * the argv pattern ``"nim", "c"`` (as passed to
##     ``startProcess`` / ``execCmd`` / ``execProcess`` / ``shellCommand`` /
##     ``runSuccess`` / ``requireSuccess`` and friends), and
##   * a bare ``nim c `` command string,
##
## and then flags the invocation ONLY when it targets a *forbidden setup
## source* (see ``ForbiddenSetupSources`` below). A bare ``nim c`` that
## compiles a fixture project, an HCR target, or any other source the
## test legitimately builds *as the behaviour under test* is NOT flagged
## — those are not setup compilation and were never in scope.
##
## ----------------------------------------------------------------------
## Allow-list (legitimate runtime compiles that stay)
## ----------------------------------------------------------------------
## The HCR / watch tests recompile a *target* program (and, in the patch
## loop, ``.o`` / patch objects) AS the behaviour under test — the
## edit → recompile → reload loop is precisely what they exercise. Those
## recompiles are inherent, not setup, and stay runtime. They never
## compile ``apps/repro/repro.nim`` or the monitor shim, so the
## forbidden-source filter already lets them through; ``AllowList``
## below enumerates the files that legitimately recompile an HCR target
## or object, each with a one-line rationale, so the intent is explicit
## and a reviewer can tell "recompiles a .o / target for the HCR loop"
## (allowed) from "compiles the repro CLI or shim as setup" (forbidden).
##
## If this test fails, do NOT add a ``nim c`` of the repro CLI or the
## monitor shim back to a test. Instead build it via the graph (it is
## already an edge — ``reprobuild.apps.repro`` /
## ``reprobuild.test_fixtures.monitor_shim``), depend on that edge from
## the test's execute edge, and assert the artifact with
## ``repro_test_support.requireBinary(path, edgeName)``.

import std/[os, strutils, unittest]

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

# ----------------------------------------------------------------------
# Forbidden setup sources.
#
# These are the *setup* sources M1–M3 hoisted into the build graph. A
# runtime ``nim c`` of any of them in a test is the regression this
# guard exists to catch. Paths are matched substring-wise against the
# slash-normalised invocation text, so both ``repoRoot / "apps" / "repro"
# / "repro.nim"`` (Nim ``/`` joins render as ``"apps", "repro",
# "repro.nim"`` — see the per-line normalisation below) and a literal
# ``"apps/repro/repro.nim"`` are caught.
# ----------------------------------------------------------------------
const ForbiddenSetupSources = [
  # The repro CLI. M1 replaced ~48 per-file ``compileNim(...,
  # "apps/repro/repro.nim", ...)`` / ``compileRepro`` shell-outs with
  # ``requireBinary(repoRoot/"build"/"bin"/"repro",
  # "reprobuild.apps.repro")``.
  "apps/repro/repro.nim",
  # The monitor shim. M2 made it a single
  # ``reprobuild.test_fixtures.monitor_shim`` ``nim c --app:lib`` graph
  # edge; ``prepareMonitorTools`` now ``requireBinary``s
  # ``build/lib/librepro_monitor_shim.<ext>`` instead of compiling these
  # interpose sources per test. Incremental-Test-Runner M7 relocated the
  # shim source from reprobuild's deleted ``repro_monitor_shim`` library
  # into the shared ``io-mon`` sibling (``io_mon/shim/*``); the build-graph
  # edge now compiles those io-mon sources. Match the io-mon paths so a
  # runtime recompile of the (relocated) shim is still caught as forbidden
  # setup.
  "io_mon/shim/macos_interpose.nim",
  "io_mon/shim/windows_interpose.nim",
  # The Linux interpose source is ``linux_preload.nim`` (LD_PRELOAD), the
  # exact file the ``reprobuild.test_fixtures.monitor_shim`` edge compiles
  # on Linux (``repro.nim``) — match it so a runtime recompile is caught.
  "io_mon/shim/linux_preload.nim",
]

# ----------------------------------------------------------------------
# Allow-list.
#
# Files that legitimately invoke ``nim c`` at runtime because the
# recompile is the behaviour under test (HCR / watch edit→reload loops),
# NOT setup. Listed explicitly so a reviewer can confirm each one
# recompiles an HCR *target* / ``.o`` / patch object and never the repro
# CLI or the shim. The forbidden-source filter already excludes these
# from failing (none of them compile a forbidden source); this list is
# the documented rationale, and the test asserts every entry still
# exists so a stale allow-list is caught.
#
# Paths are relative to the repo root, slash-normalised.
# ----------------------------------------------------------------------
const AllowList: array[2, tuple[path, rationale: string]] = [
  ("tests/e2e/hcr-debug-unwind/t_e2e_hcr_direct_patch_debug_unwind_replay.nim",
   "compiles the HCR target program (hcr_m28_target.nim) that the " &
   "direct-patch / debug-unwind replay loop patches — the recompiled " &
   "target IS the subject under test, not setup."),
  ("tests/e2e/hcr-direct-linker/t_e2e_hcr_in_target_link_and_trampoline.nim",
   "compiles the HCR target program (hcr_m27_target.nim) that the " &
   "in-target link + trampoline patch loop rewrites — the recompiled " &
   "target IS the subject under test, not setup."),
]

type Offence = object
  file: string   ## repo-root-relative path
  lineNo: int
  line: string   ## the offending source line (stripped)
  source: string ## the forbidden setup source it compiles

proc stripComment(line: string): string =
  ## Drop a trailing line comment so a forbidden source mentioned only in
  ## prose (e.g. the M1 conversion notes) is never flagged. We do not try
  ## to honour ``#`` inside string literals — a real ``nim c`` invocation
  ## that compiles a forbidden source would have the source token before
  ## any ``#``, so this conservative split keeps live code intact while
  ## silencing documentation.
  let stripped = line.strip(leading = true, trailing = false)
  if stripped.startsWith("#"):
    return ""
  let hashIdx = line.find('#')
  if hashIdx >= 0:
    return line[0 ..< hashIdx]
  line

proc stripBacktickSpans(text: string): string =
  ## Drop ``backtick``-delimited spans. A real ``nim c`` invocation is
  ## never wrapped in backticks; the only lines that embed ``nim c`` in
  ## backticks are the *diagnostic hint strings* of the converted
  ## ``fileExists`` asserts (e.g. ``"...; build with `nim c
  ## apps/repro/repro.nim` first"``) — those are the correct M1 pattern
  ## telling the user how to produce the missing graph artifact, NOT a
  ## runtime compile. Removing backtick spans before the bare-command
  ## scan keeps those hints from being flagged while leaving any
  ## genuine ``nim c`` argv untouched.
  result = ""
  var inSpan = false
  for ch in text:
    if ch == '`':
      inSpan = not inSpan
      continue
    if not inSpan:
      result.add(ch)

proc mentionsRuntimeNimCompile(text: string): bool =
  ## True when ``text`` looks like a runtime ``nim c`` invocation: either
  ## the argv pattern ``"nim", "c"`` (whitespace-insensitive) or a bare
  ## ``nim c `` command string (outside any backtick hint span).
  let collapsed = text.replace(" ", "").replace("\t", "")
  # Adjacent argv tokens: ``["nim", "c", ...]`` (the dominant
  # ``shellCommand`` / seq-of-string form).
  if "\"nim\",\"c\"" in collapsed:
    return true
  # Split argv form: ``startProcess("nim", args = ["c", ...])`` — the
  # command and its first subcommand sit in different argument lists, so
  # ``"nim"`` and ``"c"`` are not adjacent. Require BOTH a standalone
  # ``"nim"`` token and a standalone ``"c"`` token; the forbidden-source
  # filter downstream guards against this over-matching (a line must
  # also name a hoisted setup source to be flagged).
  if "\"nim\"" in collapsed and ("\"c\"" in collapsed or ",\"c\"" in collapsed):
    return true
  # Bare command string: ``nim c <args>``. Normalise runs of whitespace
  # in the (backtick-stripped) text so ``nim   c`` matches too.
  var prev = ' '
  var normalized = ""
  for ch in stripBacktickSpans(text):
    if ch in {' ', '\t'}:
      if prev != ' ':
        normalized.add(' ')
      prev = ' '
    else:
      normalized.add(ch)
      prev = ch
  "nim c " in normalized

proc scanFile(repoRoot, relPath: string; offences: var seq[Offence]) =
  let content = readFile(repoRoot / relPath)
  var lineNo = 0
  for rawLine in content.splitLines():
    inc lineNo
    let line = stripComment(rawLine)
    if line.len == 0:
      continue
    if not mentionsRuntimeNimCompile(line):
      continue
    # Match the forbidden source against backtick-stripped text only, so
    # a hint string like ``build with `nim c apps/repro/repro.nim` `` —
    # the correct converted ``fileExists`` diagnostic — is not flagged.
    let code = stripBacktickSpans(line)
    # Normalise so a Nim ``a / "b" / "c"`` path join — which renders the
    # tokens as ``"a", "b", "c"`` — and a literal ``"a/b/c"`` both match
    # the forbidden ``a/b/c`` substring.
    let normalized = code
      .replace("\\", "/")
      .replace("\"", "")
      .replace(" ", "")
      .replace("\t", "")
      .replace(",", "/")
      .replace("//", "/")
    for src in ForbiddenSetupSources:
      let needle = src.replace("/", "")  # collapse the comma->slash noise
      # Match either the collapsed slash-free token sequence (path joins)
      # or the intact ``a/b/c`` literal.
      if needle in normalized.replace("/", "") or src in code.replace("\\", "/"):
        offences.add(Offence(file: relPath, lineNo: lineNo,
          line: line.strip(), source: src))
        break

proc collectTestFiles(repoRoot: string): seq[string] =
  ## All scannable test sources under the three discovery roots, as
  ## repo-root-relative slash-normalised paths. Mirrors the roots
  ## ``scripts/generate_test_edges.nim`` walks, but includes ``.sh`` (for
  ## bare ``nim c`` command strings) and is not restricted to the
  ## ``t_``/``test_`` filename prefixes — a helper module without that
  ## prefix could still hide a forbidden compile.
  result = @[]
  let selfRel = currentSourcePath()
    .replace("\\", "/")
    .split(repoRoot.replace("\\", "/") & "/")[^1]

  proc walk(repoRoot, root: string; requireTestsParent: bool;
            selfRel: string; acc: var seq[string]) =
    let abs = repoRoot / root
    if not dirExists(abs):
      return
    for path in walkDirRec(abs, relative = true):
      let normalized = (root & "/" & path).replace('\\', '/')
      if requireTestsParent:
        # ``libs/<lib>/tests/...`` and ``tools/<tool>/tests/...`` only.
        let parts = normalized.split('/')
        if parts.len < 3: continue
        if parts[2] != "tests": continue
      if not (normalized.endsWith(".nim") or normalized.endsWith(".sh")):
        continue
      if normalized == selfRel:
        continue
      acc.add(normalized)

  walk(repoRoot, "tests", requireTestsParent = false, selfRel, result)
  walk(repoRoot, "libs", requireTestsParent = true, selfRel, result)
  walk(repoRoot, "tools", requireTestsParent = true, selfRel, result)

suite "t_no_runtime_compilation_in_tests":
  test "no test source compiles a hoisted setup source at runtime":
    let repoRoot = findRepoRoot()
    let files = collectTestFiles(repoRoot)
    check files.len > 0

    var offences: seq[Offence] = @[]
    for rel in files:
      scanFile(repoRoot, rel, offences)

    if offences.len > 0:
      var msg = "Test-Fixtures-In-Build-Graph M4 guard FAILED: " &
        $offences.len & " runtime compile(s) of a hoisted setup source " &
        "found in test code.\n\n"
      for o in offences:
        msg.add("  " & o.file & ":" & $o.lineNo & "\n")
        msg.add("    compiles forbidden setup source: " & o.source & "\n")
        msg.add("    >> " & o.line & "\n")
      msg.add(
        "\nThese sources are reprobuild build-graph edges " &
        "(reprobuild.apps.repro / reprobuild.test_fixtures.monitor_shim).\n" &
        "Do NOT recompile them at test runtime. Instead:\n" &
        "  1. depend on the edge from the test's execute edge, and\n" &
        "  2. assert the artifact with " &
        "repro_test_support.requireBinary(path, edgeName).\n" &
        "See libs/repro_test_support/src/repro_test_support.nim and " &
        "Test-Fixtures-In-Build-Graph.md.\n")
      checkpoint(msg)
    check offences.len == 0

  test "allow-list entries still exist (no stale exceptions)":
    # The allow-list documents the legitimate HCR/watch runtime
    # recompiles. If an allow-listed file is renamed/removed, this fails
    # so the stale rationale is pruned rather than silently outliving its
    # subject.
    let repoRoot = findRepoRoot()
    for entry in AllowList:
      checkpoint(entry.path & " — " & entry.rationale)
      check fileExists(repoRoot / entry.path)
