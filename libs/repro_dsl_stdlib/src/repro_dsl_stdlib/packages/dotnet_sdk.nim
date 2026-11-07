## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 10.0.300

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package `dotnet-sdk`:
  provisioning:
    tarball url = "https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.300/dotnet-sdk-10.0.300-win-x64.zip",
      sha512 = "32446eddffc5a485f58f9d79cdab3a1a9adab4adc2ef0e4c787cfbb2465020d50beaadc54d40f0850e2e0089edd09864d12d6c19c526319819d57a4c00d38518",
      archiveType = "zip",
      executablePath = "dotnet.exe",
      version = "10.0.300",
      packageId = "dotnet-sdk@10.0.300",
      env = "DOTNET_ROOT=${prefix}",
      env = "MSBuildSDKsPath=${prefix}\\sdk\\$version\\Sdks",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.300/dotnet-sdk-10.0.300-win-arm64.zip",
      sha512 = "86a6ab513ba16b6dfbe8497c5eb8ee9791819c6a0d8dfffc8eee6c7d6387718f9e486010da24c354e1f4be5f99286e78a799848ee806a67b8b9fec6e4bf773cd",
      archiveType = "zip",
      executablePath = "dotnet.exe",
      version = "10.0.300",
      packageId = "dotnet-sdk@10.0.300",
      env = "DOTNET_ROOT=${prefix}",
      env = "MSBuildSDKsPath=${prefix}\\sdk\\$version\\Sdks",
      cpu = "aarch64",
      os = "windows"
