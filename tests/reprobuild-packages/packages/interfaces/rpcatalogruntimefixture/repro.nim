## Fixture for `t_dependency_lists_resolve_reprobuild_packages_interface`: a
## package defined only in a `reprobuild-packages`-shaped catalog, named by a
## consumer's `runtimeDeps:` block. It is distinct from `rpcatalogfixture` so
## the runtime-dependency case cannot pass on the native-dependency case's
## import.

import repro_project_dsl

package rpcatalogruntimefixture:
  provisioning:
    tarball url = "https://example.invalid/rpcatalogruntimefixture-2.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rpcatalogruntimefixture",
      packageId = "rpcatalogruntimefixture@2.0",
      lockIdentity = "tarball:rpcatalogruntimefixture@2.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
