## W2 — no surface that ACTIVATES a dev environment may be silent about a
## declared ``uses:`` producer pin it did not put into effect.
##
## Milestone: ``Windows-Cacheable-Builds-Session-Residuals.milestones.org``
## §W2. Companions: ``t_w2_dev_env_producer_pin_binding.nim`` (the
## classification) and ``tests/e2e/dev-env/t_e2e_dev_env_binds_materialized_producer.nim``
## (which binary actually ran, and the ``--foreground`` session arm).
##
## This is a structural audit over the source, in the same spirit as
## ``t_s7_build_paths_reach_the_restore_config.nim``, and it is that shape for
## the same reason: the defect it guards is invisible to every behavioural
## test. A NEW activation surface opts out by simply not passing the ops.
## Nothing fails. Nothing is slow. The new surface just silently answers a
## declared ``uses:`` producer name from the ambient PATH, which is precisely
## the pre-W2 behaviour W2 removed.
##
## THE POPULATION BOUNDARY, AND WHY IT MOVED
##
## The first version of this audit swept "call sites of four activation entry
## points that are missing ops". It passed, and three real violations were
## invisible to it at the same time:
##
##   1. ``repro dev --foreground`` / ``repro up --foreground``. The opt-out was
##      not at a call site at all — it was in an OBJECT CONSTRUCTION. Nim
##      zero-fills a field nobody mentions, so ``supervisorConfig`` produced a
##      config whose producer callback was ``nil``, the foreground arm handed
##      that straight to the supervisor, and only the detached arm (which
##      rebuilds the config in a child process) ever set it. Nothing in a
##      four-entry-point sweep can see a field that was not written.
##   2. ``__repro-native-shell-activate`` — the ``repro hooks ensure --shell
##      bash|zsh|fish|powershell`` prompt-time surface. Its call site DID carry
##      an opt-out marker, so the audit was satisfied; but the marker only
##      justified not BINDING, and the surface reported nothing either. "Has a
##      marker" is not "is not silent".
##   3. ``__repro-direnv-activate`` — the ``--shell-direnv`` surface. It
##      activates through ``renderDevEnvShellOps``, which was not one of the
##      four entry points, so it was outside the population entirely.
##
## The boundary is now "surfaces that activate a dev environment", which adds
## ``renderDevEnvShellOps`` (the shell-fragment renderer the direnv surface
## emits through) and ``runDevSessionSupervisor`` (a dev session activates an
## environment per service start and per watch cycle; making its resolver a
## REQUIRED PARAMETER rather than a config field is what converted defect 1
## from an invisible omission into a visible argument at a call site this audit
## reads).
##
## THE RULE, in two parts, because W2's rule has two halves:
##
##   * BIND, or say why not. Every call site either threads producer ops
##     through or carries a ``# W2-no-producer-ops:`` marker with a reason.
##   * REPORT anyway. A site that declines to bind must still be a surface that
##     REPORTS — its enclosing proc must call ``devEnvProducerActivation``.
##     A site that can do neither carries the stronger
##     ``# W2-no-producer-ops-and-no-report:`` marker, which has to argue why
##     reporting is impossible or actively harmful, not merely inconvenient.
##
## The markers are comments the author has to write, not names on a list in
## this file: an opt-out should cost a sentence of justification at the call
## site, where the next reader is.
##
## Falsifiability, verified by construction — each of the three defects above
## was re-introduced in turn and this file fails on each:
##
##   1. ``runDevSessionSupervisor(config, nil)`` on the foreground arm — case
##      "threads producer ops or states why not", naming file:line. (The
##      ORIGINAL shape of defect 1, an unset config field, no longer compiles:
##      the resolver has no default.)
##   2. deleting the ``devEnvProducerActivation`` call from
##      ``renderNativeShellTransition`` — case "an opt-out that does not bind
##      still reports".
##   3. deleting it from ``runReproDirenvActivationHelper``, or deleting the
##      marker there — cases "still reports" and "threads producer ops or
##      states why not" respectively.
##
## Also reproduced: dropping the ops from the ``repro exec`` call site, and
## from either ``dev_session.nim`` activation.

import std/[os, strutils, unittest]

const
  RepoMarker = "repro.nim"

  OptOutMarker = "# W2-no-producer-ops:"
    ## "Does not BIND." A site carrying this must still REPORT.

  SilentOptOutMarker = "# W2-no-producer-ops-and-no-report:"
    ## "Does not bind and cannot report." Strictly stronger, and deliberately
    ## uglier to type. Neither marker is a prefix of the other, so
    ## ``startsWith`` classifies them without ambiguity.

  ReportTokens = ["devEnvProducerActivation("]
    ## What "this surface reports its pins" looks like in source. The
    ## resolve-and-report wrapper is the only way notices reach stderr, so its
    ## presence in the enclosing proc is the whole predicate.

  ## Every entry point through which a dev environment gets ACTIVATED — an
  ## environment is built and something runs in it, or the script that will
  ## build it is emitted. Each takes an optional ``extraOps`` (or, for the
  ## supervisor, a required resolver); a caller that omits it activates an
  ## environment with no producer pins in it.
  ActivationEntryPoints = [
    "activatedEnvironment(",
    "runActivatedCommand(",
    "spawnActivatedShell(",
    "renderDevEnvArtifact(",
    "renderDevEnvShellOps(",
    "runDevSessionSupervisor("
  ]

  ## Tokens that count as "this call site threads the ops through". Either the
  ## resolved ops themselves, the parameter a wrapper forwards, or the named
  ## resolver a dev session is driven with. Matched case-INSENSITIVELY so that
  ## ``devEnvProducerOpsResolver`` counts without being spelled out here as a
  ## name on a list — the point is that something producer-op-shaped is passed.
  ## ``nil`` matches nothing, which is the case that matters.
  ThreadedTokens = ["extraops", "producerops"]

  ## Audited sources: every module that ACTIVATES a dev environment. The
  ## activation library itself is excluded — it is the callee.
  AuditedSources = [
    "libs/repro_cli_support/src/repro_cli_support.nim",
    "libs/repro_cli_support/src/repro_cli_support/dev_session.nim"
  ]

type
  OptOutKind = enum
    ookNone         ## no marker
    ookEmpty        ## marker present, no reason written
    ookNoBind       ## ``# W2-no-producer-ops:`` — must still report
    ookNoBindNoReport ## ``# W2-no-producer-ops-and-no-report:``

  CallSite = object
    file: string
    line: int      ## 1-based
    entryPoint: string
    text: string   ## the full call, across however many lines it spans
    optOut: OptOutKind
    optOutReason: string
    enclosingProc: string
    enclosingReports: bool

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc parenDelta(line: string): int =
  ## Net paren depth of a line, ignoring parens inside string literals and
  ## after a ``#`` comment. Crude but sufficient for Nim call arguments, and
  ## a miscount can only make the captured call text LONGER, never shorter —
  ## which would make the audit more permissive, so the failure direction is
  ## checked by the mutation runs rather than argued.
  var inString = false
  var i = 0
  while i < line.len:
    let ch = line[i]
    if inString:
      if ch == '\\':
        inc i
      elif ch == '"':
        inString = false
    else:
      case ch
      of '"': inString = true
      of '#': return result
      of '(', '[': inc result
      of ')', ']': dec result
      else: discard
    inc i

proc isTopLevelProc(line: string): bool =
  line.startsWith("proc ") or line.startsWith("func ") or
    line.startsWith("template ") or line.startsWith("iterator ")

proc enclosingProcSpan(lines: openArray[string]; index: int):
    tuple[name: string; first, last: int] =
  ## The top-level routine containing ``lines[index]``: everything from its
  ## header down to the line before the next top-level routine header.
  result = (name: "<file scope>", first: 0, last: lines.high)
  var i = index
  while i >= 0:
    if lines[i].isTopLevelProc():
      result.first = i
      var header = lines[i].strip()
      let paren = header.find('(')
      if paren > 0:
        header = header[0 ..< paren]
      result.name = header
      break
    dec i
  var j = max(index, result.first) + 1
  while j < lines.len:
    if lines[j].isTopLevelProc():
      result.last = j - 1
      return
    inc j
  result.last = lines.high

proc spanReports(lines: openArray[string]; first, last: int): bool =
  ## Does this routine call the resolve-and-report pass? COMMENT lines are
  ## excluded on purpose: an opt-out marker that merely NAMES
  ## ``devEnvProducerActivation`` must not be able to satisfy the requirement
  ## to actually call it.
  for i in first .. last:
    let stripped = lines[i].strip()
    if stripped.startsWith("#"):
      continue
    let code =
      block:
        let hash = lines[i].find('#')
        if hash >= 0: lines[i][0 ..< hash] else: lines[i]
    for token in ReportTokens:
      if code.contains(token):
        return true
  false

proc collectCallSites(repoRoot: string): seq[CallSite] =
  for relative in AuditedSources:
    let path = repoRoot / relative
    doAssert fileExists(path), "audited source is missing: " & relative
    let lines = readFile(path).splitLines()
    for index, raw in lines:
      let stripped = raw.strip()
      # A definition or forward declaration is not a call site.
      if stripped.startsWith("proc ") or stripped.startsWith("#"):
        continue
      for entry in ActivationEntryPoints:
        if not raw.contains(entry):
          continue
        var text = raw
        var depth = parenDelta(raw)
        var cursor = index
        while depth > 0 and cursor + 1 < lines.len:
          inc cursor
          text.add("\n")
          text.add(lines[cursor])
          depth += parenDelta(lines[cursor])
        # The opt-out marker introduces the comment block immediately above the
        # call. Walk back over contiguous comment lines to find it, then take
        # the WHOLE block from the marker down as the stated reason — a
        # justification worth writing rarely fits on the marker line itself.
        var markerAt = -1
        var markerKind = ookNone
        var back = index - 1
        while back >= 0 and lines[back].strip().startsWith("#"):
          let text = lines[back].strip()
          if text.startsWith(SilentOptOutMarker):
            markerAt = back
            markerKind = ookNoBindNoReport
          elif text.startsWith(OptOutMarker):
            markerAt = back
            markerKind = ookNoBind
          dec back
        var reason = ""
        if markerAt >= 0:
          let markerText =
            if markerKind == ookNoBindNoReport: SilentOptOutMarker
            else: OptOutMarker
          var parts: seq[string] = @[]
          for i in markerAt ..< index:
            var comment = lines[i].strip()
            if comment.startsWith("#"):
              comment = comment[1 .. ^1].strip()
            if comment.startsWith(markerText[2 .. ^1]):
              comment = comment[markerText.len - 2 .. ^1].strip()
            if comment.len > 0:
              parts.add(comment)
          reason = parts.join(" ")
          if reason.len == 0:
            markerKind = ookEmpty
        let span = enclosingProcSpan(lines, index)
        result.add(CallSite(file: relative, line: index + 1,
          entryPoint: entry, text: text,
          optOut: markerKind, optOutReason: reason,
          enclosingProc: span.name,
          enclosingReports: spanReports(lines, span.first, span.last)))
        break

proc threadsProducerOps(site: CallSite): bool =
  let haystack = site.text.toLowerAscii()
  for token in ThreadedTokens:
    if haystack.contains(token):
      return true
  false

proc describe(site: CallSite): string =
  site.file & ":" & $site.line & " " & site.entryPoint & " in " &
    site.enclosingProc

suite "w2_activation_surfaces_declare_producer_ops":

  test "the audit actually finds the activation call sites":
    # A population audit that sweeps an EMPTY population passes vacuously and
    # is worse than no test, so the population is asserted first. The bound is
    # deliberately loose (this is not a call-site count baseline to maintain);
    # it only has to prove the scanner is not looking at nothing.
    let sites = collectCallSites(findRepoRoot())
    for site in sites:
      checkpoint(site.describe() &
        (if site.optOut != ookNone: "  [opt-out]" else: "") &
        (if site.enclosingReports: "  [reports]" else: ""))
    check sites.len >= 12
    var files: seq[string] = @[]
    for site in sites:
      if site.file notin files:
        files.add(site.file)
    # Both audited modules must contribute, otherwise a path typo in
    # ``AuditedSources`` would silently shrink the population to one file.
    check files.len == AuditedSources.len

    # Every entry point must contribute at least one site. This is the guard
    # the FIRST version of this audit lacked in spirit: a name in the list that
    # matches nothing is indistinguishable from a surface that does not exist,
    # and ``renderDevEnvShellOps`` was outside the list entirely while the
    # direnv surface activated through it.
    for entry in ActivationEntryPoints:
      var found = 0
      for site in sites:
        if site.entryPoint == entry:
          inc found
      checkpoint(entry & " -> " & $found & " call site(s)")
      check found >= 1

  test "every activation call site threads producer ops or states why not":
    let sites = collectCallSites(findRepoRoot())
    var offenders: seq[string] = @[]
    var optOuts: seq[string] = @[]
    for site in sites:
      if site.threadsProducerOps():
        continue
      case site.optOut
      of ookNoBind, ookNoBindNoReport:
        optOuts.add(site.describe() & " — " & site.optOutReason)
      of ookEmpty:
        offenders.add(site.describe() &
          "  (opt-out marker present but carries no reason)")
      of ookNone:
        offenders.add(site.describe() &
          "  (no producer ops and no " & OptOutMarker & " marker)")
    for entry in optOuts:
      checkpoint("declared opt-out: " & entry)
    for entry in offenders:
      checkpoint("OFFENDER: " & entry)
    check offenders.len == 0

  test "an opt-out that does not bind still reports":
    # W2's rule has two halves and the first version of this audit only
    # enforced the first. ``__repro-native-shell-activate`` carried a perfectly
    # well-argued marker explaining why it must not BIND, and was silent — no
    # notice, no bin dir, bound pin or not. A marker justifies declining to put
    # a pin into effect; it does not license saying nothing about it.
    #
    # A site that genuinely cannot report either must say so with the stronger
    # marker, whose reason is then read by the case below.
    let sites = collectCallSites(findRepoRoot())
    var silent: seq[string] = @[]
    var reporting: seq[string] = @[]
    for site in sites:
      if site.threadsProducerOps() or site.optOut != ookNoBind:
        continue
      if site.enclosingReports:
        reporting.add(site.describe())
      else:
        silent.add(site.describe() &
          "  (declines to bind but its enclosing routine never calls " &
          ReportTokens[0] & " — either report, or use " &
          SilentOptOutMarker & ")")
    for entry in reporting:
      checkpoint("non-binding but reporting: " & entry)
    for entry in silent:
      checkpoint("SILENT: " & entry)
    check silent.len == 0
    # And the non-binding-but-reporting population is not empty, so this case
    # cannot pass by there being nothing to check.
    check reporting.len >= 2

  test "the opt-outs are the known ones, and are still the known ones":
    # Not a count baseline for its own sake: each of these is load-bearing and
    # its reason is argued in W2's DONE section. A NEW one appearing means
    # somebody decided a new surface should not bind producers, which is a
    # decision that belongs in the milestone rather than in a comment.
    let sites = collectCallSites(findRepoRoot())
    var noBind: seq[CallSite] = @[]
    var noReport: seq[CallSite] = @[]
    for site in sites:
      if site.threadsProducerOps():
        continue
      case site.optOut
      of ookNoBind: noBind.add(site)
      of ookNoBindNoReport: noReport.add(site)
      else: discard
    for site in noBind & noReport:
      checkpoint(site.describe() & " — " & site.optOutReason)

    # Two surfaces report without binding: the native-shell transition script
    # and the direnv activation fragment. Both are prompt-time hook surfaces.
    check noBind.len == 2
    var noBindProcs = ""
    for site in noBind:
      noBindProcs.add(site.enclosingProc & " ")
    check noBindProcs.contains("renderNativeShellTransition")
    check noBindProcs.contains("runReproDirenvActivationHelper")

    # The native-shell reason must NOT be the tamper seal. That was the reason
    # recorded before this fix pass and it was false: the M75 seal covers
    # ``dev-env export``'s plan, which this surface never builds. The stated
    # reason has to be the artifact-derived unload, because that is the one
    # that is actually true and the one a future author has to defeat before
    # binding here.
    var nativeReason = ""
    for site in noBind:
      if site.enclosingProc.contains("renderNativeShellTransition"):
        nativeReason = site.optOutReason
    check nativeReason.len > 0
    check nativeReason.contains("nativePathRemovals")
    check not nativeReason.contains("TAMPER-SEALED")

    # Two surfaces can do neither: ``repro develop``'s synthesized artifact
    # (no ``toolProfiles`` to classify, so a report would be a guaranteed
    # no-op) and the cache-keyed shell-fragment BUILD ACTION (a notice emitted
    # only on a cache miss is worse than none).
    check noReport.len == 2
    var noReportProcs = ""
    for site in noReport:
      noReportProcs.add(site.enclosingProc & " ")
    check noReportProcs.contains("runInDevelopEnvironment")
    check noReportProcs.contains("runDevEnvShellRenderHelper")
    var reasons = ""
    for site in noReport:
      reasons.add(site.optOutReason)
    check reasons.contains("SYNTHESIZED")
    check reasons.contains("BUILD ACTION")
