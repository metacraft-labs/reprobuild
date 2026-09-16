## ``wix`` — the WiX v3 toolset as electron-builder packages it.
##
## **Why this and not ``wix3_tools``.** Both provide ``candle.exe`` and
## ``light.exe`` from WiX v3, but they are different builds from different
## publishers, and which one a project needs is decided by its consumer.
## electron-builder's MSI target fetches this exact artifact — its
## ``MsiTarget.ts`` calls ``getBinFromUrl("wix", "4.0.0.5512.2", …)`` against
## the ``electron-builder-binaries`` repository — so a project that builds an
## MSI through electron-builder wants the byte-identical toolset rather than
## an equivalent one, and gets to skip the ad-hoc download at build time.
##
## ``wix3_tools`` remains the right choice for anything driving WiX directly.
##
## The ``4.0.0.5512.2`` string is electron-builder's PACKAGING tag, not a WiX
## version: the binaries inside are the WiX v3 toolset (candle / light), not
## the unified WiX v4 ``wix.exe``. Both live flat at the archive root.
##
## Windows only, and not because the other platforms are unpackaged: WiX v3
## is a .NET Framework toolset that builds Windows Installer databases, and
## neither half of that exists elsewhere.

import repro_project_dsl

const WixPackagingTag = "4.0.0.5512.2"

package wix:
  provisioning:
    tarball url = "https://github.com/electron-userland/electron-builder-binaries/releases/download/wix-" &
        WixPackagingTag & "/wix-" & WixPackagingTag & ".7z",
      sha256 = "fe677fcd837b18c9b912985d91636bbd8a1e800c3b3a6a841b6f96e89624e839",
      archiveType = "7z",
      executablePath = "candle.exe",
      packageId = "wix@" & WixPackagingTag,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:wix@" & WixPackagingTag &
        ":windows-x86_64:sha256:fe677fcd837b18c9b912985d91636bbd8a1e800c3b3a6a841b6f96e89624e839"
