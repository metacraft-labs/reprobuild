## A2–A4 HTTP-gate test-helper entry point.
##
## A thin uniquely-named wrapper that `include`s the shipping
## `repro_binary_cache` entry module verbatim. It exists ONLY so this
## build produces a distinct Nim `projectName`, and therefore a distinct
## linker response file (`<projectName>_linkerArgs.txt`, which Nim writes
## into its CWD and deletes after linking — see `compiler/extccomp.nim`).
## Compiling the same source under the same projectName in two concurrent
## build actions makes them race on that shared file; a unique entry
## module name removes the collision at the source. The produced binary is
## byte-for-byte the plain (`-d:ssl`-off) helper.
include "repro_binary_cache.nim"
