## A fixture `reprobuild-packages` catalog entry: a macOS application
## realized from a disk image, so its selection for the darwin targets places
## an application bundle and `repro home export` classifies it
## `applications` there (`concerns.packages`). Selection is static metadata:
## the URL is never fetched and the digest is a placeholder.
##
## Reached as `$REPROBUILD_PACKAGES_ROOT` (the m83 intent-export gate, and
## `packagesCatalog` in the flake's `lib-intent-ifd` check), so the
## classification does not depend on a workspace sibling.

import repro_project_dsl

package gm7app:
  provisioning:
    tarball url = "https://example.invalid/gm7/GM7App-1.0.dmg",
      sha256 = "7777777777777777777777777777777777777777777777777777777777777777",
      archiveType = "dmg",
      installMethod = "app-bundle",
      appBundle = "GM7App.app",
      bundleId = "dev.reprobuild.gm7.fixtureapp",
      teamId = "RPBTEST777",
      version = "1.0",
      executablePath = "GM7App.app/Contents/MacOS/GM7App",
      packageId = "gm7app@1.0",
      cpu = "any",
      os = "macos",
      lockIdentity = "tarball:gm7app@1.0:macos-any:sha256:7777"
