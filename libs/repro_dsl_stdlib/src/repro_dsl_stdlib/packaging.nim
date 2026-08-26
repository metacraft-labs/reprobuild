## The DSL packaging layer (CPack analog) — public facade.
##
## ``import repro_dsl_stdlib/packaging`` brings the whole family into a
## recipe: the typed install-tree definition (``Distribution`` +
## ``distribution`` / ``runtimeContract`` / ``service`` /
## ``packageMetadata``), the §5 runtime-wrapper / RPATH / env-default
## contract (applied uniformly by every producer), and the M0 format
## producers ``deb`` / ``rpm`` / ``tarball``. Importing this module also
## registers the backend tool identities (``sh`` / ``tar`` / ``dpkg-deb``
## / ``rpmbuild``) so a recipe's ``uses:`` selectors and the
## ``toolIdentityRefs`` resolver bind them.
##
## See ``reprobuild-specs/Distribution-And-Packaging.md`` §5–§6 and the
## ``M0 PACKAGING-LAYER`` milestone. A worked recipe lives at
## ``examples/two-binary-dist/reprobuild.nim``.

import repro_dsl_stdlib/packaging/install_tree
import repro_dsl_stdlib/packaging/producers

export install_tree
export producers
