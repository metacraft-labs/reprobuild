## Fixture for `t_dependency_lists_resolve_reprobuild_packages_interface`: a
## catalog package whose module exports a `shell` of its own, as the `sh`
## package's does beside the DSL's `shell`. A consumer that names it only in
## `nativeBuildDeps:` and calls the DSL's `shell(...)` compiles only when the
## import leaves that name out.

import repro_project_dsl

proc shell*(command: string; args: seq[string] = @[]): string =
  ## Overlaps the DSL's `shell(command)`: a call with one string argument is
  ## ambiguous when both are in scope.
  command

package rpcatalogshellfixture:
  provisioning:
    tarball url = "https://example.invalid/rpcatalogshellfixture-3.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rpcatalogshellfixture",
      packageId = "rpcatalogshellfixture@3.0",
      lockIdentity = "tarball:rpcatalogshellfixture@3.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
