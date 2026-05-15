# CodeTracer Subset

Tiny fixture that mirrors a narrow CodeTracer-style build shape without claiming
the macOS replacement behavior is implemented. Later tests can use this as a
small source tree for provider, external package, and monitor experiments.

Expected command shape:

```sh
nim c -r src/trace_subset.nim fixtures/sample.trace
```
