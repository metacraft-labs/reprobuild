## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 8.5.6

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package php:
  provisioning:
    tarball url = "https://downloads.php.net/~windows/releases/archives/php-8.5.6-Win32-vs17-x64.zip",
      sha256 = "38c20264dcfb098cbec3b2b25bc21312e436b87dceadc76725aa1d7cf80be1fc",
      archiveType = "zip",
      executablePath = "php.exe",
      extraExecutable = "php-cgi.exe",
      extraExecutable = "phpdbg.exe",
      version = "8.5.6",
      packageId = "php@8.5.6",
      env = "PHP_INI_SCAN_DIR=${prefix}\\cli;${prefix}\\cli\\conf.d;",
      cpu = "x86_64",
      os = "windows"
