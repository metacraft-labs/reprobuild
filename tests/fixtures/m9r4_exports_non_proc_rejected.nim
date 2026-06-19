## DSL-port M9.R.4 — manual-verification fixture for the
## "non-proc nodes inside ``exports:`` are rejected" contract.
##
## This file is **intentionally non-compiling**. The
## ``library api: exports:`` sub-block walked by
## ``m9r4CollectExports`` (``libs/repro_project_dsl/src/repro_project_dsl/macros_b.nim``)
## raises a compile-time ``error()`` for any child node whose ``kind``
## is not ``nnkProcDef``. A ``let`` statement is the canonical wrong
## shape an author would try first.
##
## Manual verification:
##
##   nim c --hints:off --warnings:off \
##     tests/fixtures/m9r4_exports_non_proc_rejected.nim
##
## Expected output (substring):
##
##   library api: exports: only accepts proc declarations; got nnkLetSection
##   ...
##   Use the shape: proc <name>*(<params>): <return>
##
## Exit code: 1 (compilation failure). DO NOT add this file to the
## test runner — its purpose is to fail.

import repro_project_dsl

package m9r4ExportsNonProcRejected:
  library libBad:
    api:
      exports:
        let x = 1
