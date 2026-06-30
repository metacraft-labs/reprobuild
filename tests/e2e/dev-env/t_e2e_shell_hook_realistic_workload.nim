## M77 — end-to-end realistic workload assertion.
##
## The milestone narrative: a user with a per-prompt hook that
## ALWAYS spawns ``repro dev-env export`` (no M76-style
## ``__REPRO_PROJECT_ROOT`` short-circuit) must still see the
## activation cost stay flat across rapid prompt evaluations. The
## fast-path cache check is the only thing standing between this
## scenario and the "every prompt re-walks the dev-env edge"
## pathology.
##
## Mechanism:
##
## * Activate once via ``repro dev-env export``; capture the emitted
##   ``__REPRO_APPLIED`` cache key.
## * Simulate 40 hook-driven prompt evaluations by spawning
##   ``repro dev-env export`` 40 more times with ``__REPRO_APPLIED``
##   pre-set in the child env. Each spawn measures wall-clock from
##   the parent side.
## * Assert two complementary bounds across the 40 prompts:
##
##     * The load-bearing bound is on the MEDIAN per-prompt latency.
##       The pathology this test guards ("every prompt re-walks the
##       dev-env edge") raises the *typical* prompt cost from a few
##       milliseconds to 100+ ms, which shows up squarely in the
##       median. The median is robust to the OS image-cache / AV-scan
##       tail spikes that make the cumulative-sum bound flaky on shared
##       CI. We reuse the per-prompt p50 bar from the
##       ``t_e2e_shell_hook_noop_latency`` microbench:
##
##         * Linux/macOS: median < 20 ms (microbench p50 CI tolerance)
##         * Windows: median < 20 ms (microbench p50 bar on a
##           Defender-enabled host)
##
##     * A loose cumulative ceiling still catches a regression where
##       the median stays low but a large fraction of prompts blow up:
##
##         * Linux/macOS: cumulative < 2000 ms (vs. 4 s+ pre-M77)
##         * Windows: cumulative < 3000 ms
##
##   The earlier load-bearing bound was a 100 ms cumulative ceiling on
##   Linux/macOS — 2.5 ms per full ``repro`` spawn, *below* the
##   microbench's own 5 ms p50 endorsement — so it flaked under any CI
##   scheduling jitter without measuring a real regression.
##
## NB: the M76 hook in production short-circuits via
## ``__REPRO_PROJECT_ROOT`` and therefore typically incurs ZERO
## subprocess spawns over a 40-prompt burst inside the same project.
## This test is a defense-in-depth assertion: a future hook change
## that drops the M76 short-circuit (or any hook variant that has to
## query ``repro`` per prompt — e.g. one that wants the fresh
## cache-key value to populate other UI) must still come in under a
## reasonable per-prompt budget thanks to the M77 fast path.

import std/[algorithm, monotimes, os, osproc, sequtils, streams, strtabs,
    strutils, times, unittest]

import repro_test_support
import shell_hook_helper

const
  Prompts = 40
  FastPathExpectedSubstring = "repro shell hook: no-op (cache key unchanged)"

# The MEDIAN per-prompt budget is the load-bearing assertion: it is
# the statistic that the "every prompt re-walks the dev-env edge"
# pathology moves (typical prompt cost jumps from a few ms to 100+ ms)
# and it is immune to the OS image-cache / AV-scan tail spikes that
# make a cumulative-sum bound flaky on shared CI. Both OS bars match
# the per-prompt p50 ceiling from ``t_e2e_shell_hook_noop_latency``.
const MedianBudgetMs = 20.0

when defined(windows):
  # Loose cumulative ceiling. Per the microbench, per-prompt p50 is
  # ~14 ms on a Defender-enabled host and the AV-scan tail spikes up to
  # ~300 ms on a handful of samples (4-5%). 40 × 14 ms ≈ 560 ms is the
  # floor; spikes can push cumulative time up to ~2000 ms. 3000 ms
  # tolerates that environmental noise while still catching a regression
  # that drops the fast path entirely (~30+ s with provider-compile
  # cache checks per prompt). Cf. ``t_e2e_shell_hook_noop_latency``.
  const CumulativeBudgetMs = 3000.0
else:
  # Loose cumulative ceiling on Linux/macOS. The pre-M77 full-edge walk
  # accumulates well over 4 s across 40 prompts; the fast path keeps the
  # whole burst comfortably under 2 s even with CI scheduling jitter.
  # This backstops the median bound against a "median low, many prompts
  # blow up" regression without flaking on tail spikes.
  const CumulativeBudgetMs = 2000.0

proc readFingerprint(script: string): string =
  const needle = "__REPRO_APPLIED='"
  let s = script.find(needle)
  if s < 0:
    raise newException(ValueError, "no __REPRO_APPLIED marker in script")
  let rest = script[(s + needle.len) .. ^1]
  let e = rest.find('\'')
  if e < 0:
    raise newException(ValueError, "unterminated __REPRO_APPLIED quote")
  rest[0 ..< e]

proc captureExportOutput(c: ShellHookCase;
                         extraEnv: openArray[(string, string)] = []):
    tuple[stdout: string; exitCode: int] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k.startsWith("__REPRO_"):
      continue
    env[k] = v
  env["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  env["HOME"] = c.tempRoot
  for (k, v) in extraEnv:
    env[k] = v
  var p = startProcess(c.reproBin,
    args = @["dev-env", "export", "bash",
      "--project-root", c.projectRoot],
    workingDir = c.repoRoot,
    env = env,
    options = {poUsePath})
  let outStream = p.outputStream
  let outText = if outStream != nil: outStream.readAll() else: ""
  let code = p.waitForExit()
  p.close()
  (stdout: outText, exitCode: code)

proc runScenario() =
  let c = prepareShellHookCase("repro-m77-realistic")
  defer:
    try: removeDir(c.tempRoot)
    except CatchableError: discard

  # Cold activation: emits the full activation script + cache-key
  # marker. We don't measure this — its cost (~1-2 s on Windows for
  # provider compile + introspection edge) dwarfs every other sample
  # and is paid ONCE per project per shell.
  let initial = captureExportOutput(c)
  check initial.exitCode == 0
  let fingerprint = readFingerprint(initial.stdout)
  check fingerprint.len > 0

  # Warm-up: 10 fast-path samples to let the OS' image cache and (on
  # Windows) Defender's first-byte scan reach steady state. These
  # samples are discarded.
  for i in 0 ..< 10:
    let r = captureExportOutput(c,
      [("__REPRO_APPLIED", fingerprint)])
    check r.exitCode == 0
    check r.stdout.contains(FastPathExpectedSubstring)

  # Measured: ``Prompts`` invocations.
  var perPrompt: seq[float] = @[]
  let t0Total = getMonoTime()
  for i in 0 ..< Prompts:
    let t0 = getMonoTime()
    let r = captureExportOutput(c,
      [("__REPRO_APPLIED", fingerprint)])
    let elapsed = getMonoTime() - t0
    let dt = float(inNanoseconds(elapsed)) / 1_000_000.0
    perPrompt.add(dt)
    # STRICT: every prompt must emit the no-op script. A regression
    # that flips one prompt onto the full walk explodes here long
    # before the cumulative budget catches it.
    check r.exitCode == 0
    check r.stdout.contains(FastPathExpectedSubstring)
  let totalElapsed = getMonoTime() - t0Total
  let totalMs = float(inNanoseconds(totalElapsed)) / 1_000_000.0
  let perPromptSum = perPrompt.foldl(a + b, 0.0)
  echo "M77 realistic workload over ", Prompts, " prompts:"
  echo "  cumulative wall-clock=", totalMs.formatFloat(ffDecimal, 1),
       " ms (sum-of-samples=", perPromptSum.formatFloat(ffDecimal, 1),
       " ms)"
  var sorted = perPrompt
  sorted.sort(system.cmp[float])
  let median = sorted[Prompts div 2]
  echo "  per-prompt min=", sorted[0].formatFloat(ffDecimal, 1),
       " p50=", median.formatFloat(ffDecimal, 1),
       " p99=", sorted[^1].formatFloat(ffDecimal, 1)
  echo "  budget: median < ", MedianBudgetMs.formatFloat(ffDecimal, 1),
       " ms, cumulative < ", CumulativeBudgetMs.formatFloat(ffDecimal, 1),
       " ms"

  # The load-bearing assertion: the MEDIAN per-prompt latency stays
  # within the fast-path budget. The pre-M77 baseline walks the full
  # dev-env edge per prompt — a provider-compile cache check + an
  # introspection cache check + an artifact read, which on a warm cache
  # takes 100+ ms per prompt — so the typical (median) prompt cost
  # explodes here. The median is robust to the OS image-cache and (on
  # Windows) AV-scan tail spikes that make a sum-of-samples bound flaky
  # on shared CI, so it measures the real "every prompt re-walks the
  # edge" pathology rather than runner noise.
  check median < MedianBudgetMs
  # Backstop: a loose cumulative ceiling still catches a regression that
  # keeps the median low while blowing up a large fraction of prompts.
  check perPromptSum < CumulativeBudgetMs

suite "e2e_shell_hook_realistic_workload":

  test "fast_path_keeps_40_prompts_under_cumulative_budget":
    if not isFsSnoopSupported:
      skip()
    else:
      runScenario()
