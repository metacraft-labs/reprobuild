# Develop-override sibling checkouts

Read-only sibling checkouts for
`libs/repro_cli_support/tests/t_develop_override_records_the_identity_it_replaced.nim`.
Each `<scenario>/libfoo` is the directory `repro develop libfoo --into=PATH`
points a per-process consumer at:

| Directory | Recipe | `VERSION` |
|---|---|---|
| `plain` | buildable, declares no variants | none |
| `plain-with-version` | same recipe | `9.8.7` (the consumer's second source) |
| `variants` | buildable, declares `enableTls` and `profile` | none |
| `variants-no-build` | declares `enableTls`, no `build:` block | none |

`plain` deliberately has no `VERSION`: the cases that assert a version was
recorded must not be able to pass through the fallback.

The paths are stable on purpose. `repro develop` obtains the sibling's
declarations through the engine's interface-extraction and provider-compile
edges, whose action-cache entries are keyed by the recipe's location, so one
compile per checkout serves every case and every run. The test never writes
here; `repro develop` writes only into the consumer.
