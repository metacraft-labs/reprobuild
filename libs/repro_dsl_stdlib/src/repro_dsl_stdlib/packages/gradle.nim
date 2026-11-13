## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 9.5.1, 8.10.2
##
## M69 (hand-edited): the ``env = "GRADLE_HOME=${prefix}"`` binding on the
## realizations below is a hand-merged M69 addition. ``GRADLE_HOME`` is the
## conventional environment variable that Gradle itself, IDEs, and the
## M41 kotlin-gradle Tier 2b probe consult; it is exported by
## ``D:/metacraft/env.ps1`` at line 407 against the metacraft-dev-deps
## prefix. The harvester does NOT auto-detect this binding from the
## Scoop manifest (Scoop's ``env_set`` block carries no ``GRADLE_HOME``
## for this package), so a re-harvest emits statements without it; keep
## the binding when merging a re-harvest, or the home archive realizer
## emits no ``GRADLE_HOME`` resource.
##
## M2 (hand-edited, 2026-05-31): the 8.10.2 version below is
## hand-merged to preserve the Gradle 8.x LTS line as a backfill for
## the ``GRADLE_VERSION=8.10.2`` pin in
## ``windows/toolchain-versions.env``. Gradle 9 (the HEAD version) is a
## major-version bump; the M2 reconciliation kept env.ps1 on 8.x and
## added the historical version so operators on a migrated home.nim
## resolve cleanly without forcing the major bump. It is the default:
## its statements come first (GM4b kept the retired catalog's default,
## its last entry), and 9.5.1 is selected by pinning it.
## URL + SHA-256 lifted from Scoop bucket commit ``df9c451c53`` (the
## "gradle: Update to version 8.10.2" commit on ScoopInstaller/Main).
## The ``--version-history`` harvester walk reproduces both versions
## *modulo* this note + the ``GRADLE_HOME`` env binding.
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization to BOTH the 9.5.1 and 8.10.2 versions. Gradle ships
## a universal cross-platform ``-all.zip`` (or ``-bin.zip``) — same
## archive, same sha256 across OSes. The Linux launcher is ``bin/gradle``
## (the bash launcher script) vs. the Windows ``bin\\gradle.bat`` —
## each realization's executablePath carries the platform-specific
## basename. The archive stays ``zip``; URL + sha256 are identical between
## the Windows and Linux realizations. As a portable Java app,
## glibc floor is whatever the underlying JDK enforces.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package gradle:
  provisioning:
    tarball url = "https://services.gradle.org/distributions/gradle-8.10.2-all.zip",
      sha256 = "2ab88d6de2c23e6adae7363ae6e29cbdd2a709e992929b48b6530fd0c7133bd6",
      archiveType = "zip",
      executablePath = "bin\\gradle.bat",
      version = "8.10.2",
      packageId = "gradle@8.10.2",
      extractPath = "gradle-8.10.2",
      env = "GRADLE_HOME=${prefix}",
      os = "windows"
    tarball url = "https://services.gradle.org/distributions/gradle-8.10.2-all.zip",
      sha256 = "2ab88d6de2c23e6adae7363ae6e29cbdd2a709e992929b48b6530fd0c7133bd6",
      archiveType = "zip",
      executablePath = "bin/gradle",
      version = "8.10.2",
      packageId = "gradle@8.10.2",
      extractPath = "gradle-8.10.2",
      env = "GRADLE_HOME=${prefix}",
      cpu = "x86_64",
      os = "linux"
    tarball url = "https://services.gradle.org/distributions/gradle-9.5.1-all.zip",
      sha256 = "c72fb9991f6025cbe337d52ba77e531b3faf62bdd3e348fe1ccee9f51c71adb0",
      archiveType = "zip",
      executablePath = "bin\\gradle.bat",
      version = "9.5.1",
      packageId = "gradle@9.5.1",
      extractPath = "gradle-9.5.1",
      env = "GRADLE_HOME=${prefix}",
      os = "windows"
    tarball url = "https://services.gradle.org/distributions/gradle-9.5.1-all.zip",
      sha256 = "c72fb9991f6025cbe337d52ba77e531b3faf62bdd3e348fe1ccee9f51c71adb0",
      archiveType = "zip",
      executablePath = "bin/gradle",
      version = "9.5.1",
      packageId = "gradle@9.5.1",
      extractPath = "gradle-9.5.1",
      env = "GRADLE_HOME=${prefix}",
      cpu = "x86_64",
      os = "linux"
