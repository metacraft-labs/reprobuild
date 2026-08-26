# Monitor Overhead

## HM-6 acceptance: in-process monitor hosting versus the CLI wrapper

`hm6_acceptance.nim` + `hm6_run.sh` are the instrument behind
In-Process-Monitor-Hosting HM-6. They answer one question: on a **real**
parallel build, is monitoring the action by calling io-mon as a library
(`BuildEngineConfig.hostMonitorInProcess`) faster than spawning
`repro internal io monitor` in front of it?

**Measured answer: no.** At `buildMaxParallelism()`'s default of 8, over 60
real `gcc -c` invocations of reprobuild's own generated C, the median
hosted/wrapped ratio was 1.013 against a ±4% within-arm spread, and the sign
of the difference was not stable across rounds — an independent re-run on the
same harness read 0.988 with a wider within-arm spread. On ~0 ms actions at the
same parallelism, hosting is consistently **slower**: 1.5–2.4x on one machine,
1.1–1.9x on a more heavily loaded one. Quote the direction and the
sign-stability contrast, not the band. `hostMonitorInProcess` stays
false. The full tables, the drift control, the sensitivity control and the
evidence comparison are recorded under HM-6 in
`reprobuild-specs/In-Process-Monitor-Hosting.milestones.org`.

### What it runs

The actions are the real compile commands reprobuild's own build issues, read
out of `build/nimcache/repro/repro.json` — the record `nim` itself writes —
rather than transcribed. The harness **raises** rather than guessing if that
record is not in the shape it expects: a benchmark that silently fell back to
a hand-written flag list would be measuring something other than the build it
claims to measure.

Both arms are the same binary and the same graph; only
`hostMonitorInProcess` differs. Both set `bypassRunQuota`, because the bypass
path is the only launch path that can host at all.

### Two controls, and why the result is worthless without them

- **Drift control** — the wrapped arm contains no hosting code, so it should
  move only with machine load. Report its spread; if it is wider than the
  between-arm gap, there is no result.
- **Sensitivity control** — `WORK=trivial` replaces each compile with a `cat`
  of a small marker, which is the ~0 ms action shape HM-4 and HM-5 measured
  and where hosting is known to lose. Without it, "no difference" and
  "a blind instrument" are the same reading. Read its SIGN STABILITY, not its
  magnitude: on cheap actions the sign holds across rounds, on real work it
  does not, and that contrast is what says the instrument can see a
  difference when there is one.

### Running it

See the header of `hm6_run.sh` for the build line and the environment knobs.
Note that `just build` does not build this harness, and neither does the
graph.

Absolute milliseconds belong to one machine at one moment and are **not** a
specification — this campaign retired three published bands for exactly that
reason. Report the ratio, the spread, the machine's load average and its live
process count together, or report nothing.
