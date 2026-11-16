## The Reprobuild recipe SDK: ``import reprobuild``.
##
## The zero-ceremony import for a ``repro.nim``. It brings the core project
## DSL (``package``, ``uses``, ``nativeBuildDeps``, ``buildDeps``,
## ``runtimeDeps``, ``executable``, ``library``, ``build``, ``tasks``,
## ``task``, ``service``, ``config``, ``glob``, ``shell``, ``aggregate``, ...)
## together with the standard prelude: the typed filesystem operations
## (``writeText``, ``copyFile``, ``stamp``, ...), configurables, the active
## build context and lock-file declarations. Packages named on a ``uses:``
## line bring their own typed tool bindings into the recipe; nothing has to be
## imported for them.
##
## The module tree under this one is the canonical import surface:
##
## ============================== =============================================
## Import                         What it provides
## ============================== =============================================
## ``reprobuild``                 this umbrella
## ``reprobuild/dsl``             the core project DSL alone, without the
##                                standard prelude (for helper modules that
##                                want the smallest compile)
## ``reprobuild/dsl/<module>``    one standard-library domain or package
##                                module, e.g. ``reprobuild/dsl/fs``,
##                                ``reprobuild/dsl/operations``,
##                                ``reprobuild/dsl/packaging``,
##                                ``reprobuild/dsl/packages/nim``
## ``reprobuild/home``            the profile DSL for a ``home.nim``
## ``reprobuild/system``          the profile DSL for a ``system.nim``
## ============================== =============================================
##
## How a compiler or an editor finds it
## ------------------------------------
##
## Only through ``--path``: the directory holding this file is one more search
## path, exactly like every other Nim library. Nothing is injected with
## ``--import:`` or ``--include:``. That is deliberate: ``--import:`` applies to
## EVERY module of a compilation, so it would put ``package``, ``service`` and
## the rest into an application's own ``src/*.nim`` (and warn
## ``[UnusedImport]`` there), while an explicit ``import reprobuild`` at the top
## of a recipe is something ``nim check``, ``nimsuggest`` and any language
## server resolve with no Reprobuild-specific flags.
##
## Older names
## -----------
##
## ``import repro_project_dsl`` (= ``reprobuild/dsl``), ``import
## repro_dsl_stdlib`` (= ``reprobuild``) and ``import
## repro_dsl_stdlib/<module>`` (= ``reprobuild/dsl/<module>``) keep working and
## denote the very same symbols, so a recipe can migrate one import at a time.
## The modules in this tree are re-exports of those libraries, which still hold
## the implementation.

import repro_dsl_stdlib
export repro_dsl_stdlib
