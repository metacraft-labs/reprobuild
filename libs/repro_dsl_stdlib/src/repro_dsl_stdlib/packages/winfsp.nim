## ``winfsp`` — the user-mode half of WinFsp, from the pinned MSI's payload.
##
## **What this package is, and what it deliberately is not.** WinFsp is two
## things in one installer: a kernel-mode filesystem driver, and a user-mode
## surface — headers, an import library, and the ``fsptool`` / ``launchctl``
## commands. The driver is loaded by the OS from a SIGNED, machine-wide
## install and cannot run out of a content-addressed prefix; no packaging
## changes that. The user-mode half is ordinary files, and those are what a
## build needs.
##
## So this package covers the half that can be covered, and the other half
## stays a declared REQUIREMENT rather than a pretence. A consumer that only
## compiles against WinFsp — ``winfsp-sys``'s build script wants
## ``inc/winfsp/winfsp.h`` and ``lib/winfsp-x64.lib`` — is fully served here.
## A consumer that MOUNTS a filesystem additionally needs the driver, and
## must check for it and fail with a message that says so; see
## ``agent-harbor/scripts/start-agentharborfs-winfsp-host-ci.ps1`` for that
## shape.
##
## **``archiveType = "msi"``.** The realize step runs
## ``msiexec /a <msi> /qn TARGETDIR=<prefix>`` — an ADMINISTRATIVE install,
## which lays the payload out at its logical hierarchy, writes files and
## nothing else, and needs no elevation. That is the distinction that makes
## an MSI packageable: a normal ``/i`` install registers services, writes the
## registry, and here would load a driver.
##
## The payload lands under ``DYNAMIC/``: ``inc/{winfsp,fuse,fuse3}``,
## ``lib/winfsp-{x64,x86,a64}.lib``, and the commands under
## ``SxS/DYNAMIC/bin/``. ``executablePath`` names the x64 ``fsptool``,
## which is both a real program and the natural anchor for the platform
## this entry targets.
##
## **The digest** is the one Agent Harbor's retired
## ``toolchain-versions.env`` carried as ``WINFSP_SHA256_MSI``, harvested
## independently of this catalog and re-verified against the upstream asset.
##
## Windows only, and not because the other platforms are unpackaged: WinFsp
## is a Windows filesystem driver framework and has no meaning elsewhere.

import repro_project_dsl

const WinFspVersion = "2.1.25156"

package winfsp:
  provisioning:
    tarball url = "https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-" &
        WinFspVersion & ".msi",
      sha256 = "073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a",
      archiveType = "msi",
      executablePath = "DYNAMIC/SxS/DYNAMIC/bin/fsptool-x64.exe",
      packageId = "winfsp@" & WinFspVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:winfsp@" & WinFspVersion &
        ":windows-x86_64:sha256:073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a"
