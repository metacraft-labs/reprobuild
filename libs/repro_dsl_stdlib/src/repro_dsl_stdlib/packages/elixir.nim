## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 1.19.5

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package elixir:
  provisioning:
    tarball url = "https://builds.hex.pm/builds/elixir/v1.19.5.zip",
      sha256 = "db6701f2232be899190ecb8dbf280104fe2434675093c2b5935e563a08052afb",
      archiveType = "zip",
      executablePath = "bin/elixir.bat",
      extraExecutable = "bin/iex.bat",
      extraExecutable = "bin/mix.bat",
      extraExecutable = "bin/elixirc.bat",
      version = "1.19.5",
      packageId = "elixir@1.19.5",
      os = "windows"
