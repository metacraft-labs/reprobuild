## ``import reprobuild/dsl`` -- the core Reprobuild project DSL, alone.
##
## The ``package`` macro and its sections (``uses``, ``nativeBuildDeps``,
## ``buildDeps``, ``runtimeDeps``, ``executable``, ``library``, ``build``,
## ``tasks``, ``task``, ``service``, ``config``) and the core runtime
## (``glob``, ``shell``, ``aggregate``, the build-action and package types).
## Unlike the ``reprobuild`` umbrella it does not load the standard prelude
## (typed filesystem operations, configurables, active build context), which
## makes it the import for a helper module that only needs the core
## vocabulary. Standard-library modules are imported individually as
## ``reprobuild/dsl/<module>``.
##
## Same symbols as the legacy ``import repro_project_dsl``: this module
## re-exports it, so the two names can be mixed during a migration.

import repro_project_dsl
export repro_project_dsl
