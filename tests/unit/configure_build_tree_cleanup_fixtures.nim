## Packages registered for ``t_configure_build_tree_cleanup``.
##
## They live in their own module because that test is compiled with
## ``reproProviderMode``: a package declared in the main module of a
## provider-mode binary emits the ``runPackageProvider`` dispatcher guarded
## on ``isMainModule``, and a package with a ``nativeBuildDeps:`` floor
## exposes dev-env introspection and so gets that dispatcher. Imported from
## here, ``isMainModule`` is false and the test binary runs its suite.
##
## The test imports this module only for the registrations its ``package``
## declarations make at module init, and names none of its symbols.

{.used.}

import repro_project_dsl

package cmakeCleanupTest:
  nativeBuildDeps:
    "chmod"
  config:
    discard

package mesonCleanupTest:
  nativeBuildDeps:
    "chmod"
  config:
    discard

package autotoolsCleanupTest:
  config:
    discard
