# Multi Project

Two-package Nim fixture for future workspace and graph-composition tests. The
`packages/mathlib` module is consumed by the `apps/consumer` program through a
local source path.

Expected command shape:

```sh
nim c --path:packages/mathlib/src -r apps/consumer/src/consumer.nim
```
