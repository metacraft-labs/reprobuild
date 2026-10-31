## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 2.10.0
##
## M5 (hand-edited): composer ships as a single
## ``composer.phar`` (a PHP archive — bytes are a phar binary that the
## ``php`` interpreter executes). The Scoop manifest's ``pre_install``
## PowerShell block synthesizes a ``composer.ps1`` invoking
## ``& php (Join-Path $PSScriptRoot "composer.phar") @args``; the M5
## ``launcherEmit`` argument declares the same synthesis declaratively
## and the home archive realizer emits the .ps1 + .cmd launcher pair
## post-extract. The interpreter (``php``) is itself a package
## (M67's ``packages/php.nim``); the operator's home.nim must list
## ``package(php); package(composer);`` for composer to realize, per
## the M5 spec's catalog-prefix-first discovery contract.
##
## **Why this differs from the auto-harvest baseline.** The auto-
## harvest landed composer with only ``composer.ps1`` as its executable,
## the plain ``extract`` install method and a ``raw`` archive but
## NO launcher emission — the pre_install PowerShell block landed in
## the unrecognized pre-install lines because it contained a multi-line
## ``@(...)`` PowerShell array literal piping into ``Add-Content``
## which the M3 allowlist does not match. M5's launcher-emit field
## sidesteps the pre_install allowlist entirely (the launcher synthesis
## is now a first-class schema concept) and emits the byte-deterministic
## launcher text the spec authors expect.
##
## A re-harvest emits the statement WITHOUT ``launcherEmit`` / with the
## (unrecognized) pre_install block; merge it by hand. The harvester
## DOES recognize composer-shaped pre_install blocks (M5 deliverable
## Part 6) and emits a launcher spec instead of the unrecognized line —
## but composer's specific pre_install also contains COMPOSER_HOME
## migration logic that the M3 allowlist does not match, so the
## post-harvest file still needs the hand-merge to keep that part out
## of the unrecognized list.
##
## **What this realization loses vs the upstream Scoop manifest**:
## the Scoop pre_install block includes a ``$persist_dir\home``
## migration check (``if (!(Test-Path "$persist_dir\home") ...``) that
## relocates an EXISTING ``%USERPROFILE%\.composer`` into the Scoop
## persist directory the first time composer is installed. The M5
## launcher-emit shape does NOT carry that one-shot migration logic —
## the COMPOSER_HOME env binding (above) still points at
## ``$persist_dir\home``, so a fresh install Just Works, but operators
## with a prior ``%USERPROFILE%\.composer`` cache will have it
## silently ignored (composer will create an empty home/ on first
## run). Restoring the migration would need a generic post-extract
## "first-run user-data migration" schema concept; that's a future M.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package composer:
  provisioning:
    tarball url = "https://getcomposer.org/download/2.10.0/composer.phar",
      sha256 = "a346538851988ead111d11e3cbd7d372eeba44abd0af412e09890d3c21ea6c31",
      archiveType = "raw",
      executablePath = "bin/composer.ps1",
      extraExecutable = "bin/composer.cmd",
      version = "2.10.0",
      packageId = "composer@2.10.0",
      env = "COMPOSER_CACHE_DIR=$persist_dir\\cache",
      env = "COMPOSER_HOME=$persist_dir\\home",
      launcherEmit = launcherEmitSpec("phar", "composer.phar", "php", "composer"),
      os = "windows"
