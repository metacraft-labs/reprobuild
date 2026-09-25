## Fixture for `t_uses_resolves_reprobuild_packages_interface`: a package
## defined only in a `reprobuild-packages`-shaped catalog, not in the stdlib.
## The test sits under `tests/integration/`, so the lookup's walk up from the
## consumer finds this `tests/reprobuild-packages` checkout first.

import repro_project_dsl

package rpcatalogfixture:
  provisioning:
    tarball url = "https://example.invalid/rpcatalogfixture-1.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rpcatalogfixture",
      packageId = "rpcatalogfixture@1.0",
      lockIdentity = "tarball:rpcatalogfixture@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
