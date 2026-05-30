## M69 — package(<id>[, "<version>"]) DSL construct re-export.
##
## Per the M69 deliverable list, this module is the spec-mandated
## home for the ``package(<id>, [<version>])`` macro that lives
## inside ``activity <name>:`` bodies. The implementation itself
## lives in ``repro_profile/macros.nim`` (the M83 Phase A macro
## library) because the macro is part of the same compile-time
## activity-body parser that handles bare-identifier package
## references, ``when`` guards, and splat helpers. This module re-
## exports the umbrella so a ``home.nim`` author can import either
## ``repro_dsl_stdlib/profile_macros`` (the M69 spec path) or the
## umbrella ``repro_profile`` and get the same shape.
##
## **Coexistence rule.** A profile may freely mix:
##
##   * bare-identifier references (the legacy form): ``neovim``
##   * the bare-call form: ``package(neovim)`` (equivalent to the
##     bare-identifier form; resolves to ``defaultVersion`` at
##     apply time)
##   * the versioned-call form: ``package(jdk, "21.0.5")`` (the
##     new M69 form; pins the exact catalog slice)
##
## All three round-trip through the structural editor; the apply
## pipeline treats the bare and bare-call forms identically.

import repro_profile
export repro_profile
