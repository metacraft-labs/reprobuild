# Reprobuild Benchmarks

Run `just bench-quick` for the abbreviated M0 benchmark suite or `just bench`
for the full M0 suite. The M0 suite measures real repository operations:
source enumeration, focused Nim checks, and full local gates in non-quick mode.

Outputs:

- `bench-results/benchmark_results.json`
- `bench-results/report.html`
