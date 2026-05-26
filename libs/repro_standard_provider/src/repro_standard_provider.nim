## Convention dispatch framework for ``repro-standard-provider`` (Tier 2b).
##
## The standard provider's job is to turn a no-``build:`` ``reprobuild.nim``
## into a fine-grained build graph by recognising the language's
## conventional source layout. This library carries the framework
## pieces — the ``LanguageConvention`` value type, the
## ``ConventionRegistry``, and a module-level ``defaultConventionRegistry``
## for the provider to consult at startup. Per-language plugin libraries
## (Nim, Rust, Go, ...) plug in by calling ``addDefaultConvention`` from
## their own startup code, mirroring how ``RegisterProvider`` shows up
## in Tier 2c.
##
## Milestone M1 only lands the framework. The standard provider still
## answers manifest requests with the M0 placeholder; on a graph
## invocation it consults ``defaultConventionRegistry`` and either
## delegates to the first matching convention or fails loudly with a
## diagnostic naming the project root and the package's ``uses:``
## hint.

import repro_standard_provider/convention
import repro_standard_provider/project_intro

export convention
export project_intro
