## ``electron-builder-nsis-resources`` — the NSIS plugin set electron-builder
## fetches beside the compiler.
##
## A second cache entry rather than part of ``electron-builder-nsis``,
## because electron-builder treats them as two: ``NsisTarget.js`` calls
## ``getBinFromUrl("nsis-resources", "3.4.1", …)`` separately, and the two
## carry independent version tags that move independently.
##
## **This package has no program in it.** The archive is a flat
## ``plugins/{x86,x64}-{ansi,unicode}/*.dll`` tree — INetC, nsis7z and
## friends, which makensis loads rather than spawns. ``executablePath``
## therefore names an ANCHOR: a file whose presence proves the realization
## completed, the same idiom ``mesa_gl_headers``, ``xorgproto``, ``hwdata``
## and ``wayland_protocols`` use for header and data trees. The realizer
## recognises a ``.dll`` declaration as a data declaration and skips the
## execute-permission check.
##
## The consequence worth knowing: the PATH entry a realized prefix
## contributes is the directory CONTAINING ``executablePath``, so this
## package puts ``plugins/x86-unicode`` on PATH. Harmless — nothing there is
## invocable — but it is not free on Windows, where the whole environment
## block is capped at 8191 characters.
##
## **Identified, not merely pinned.** The SHA-512 of this artifact matches
## the constant ``NsisTarget.js`` passes to ``getBinFromUrl`` byte for byte.
##
## Windows only, for the same reason as its sibling.

import repro_project_dsl

const ElectronBuilderNsisResourcesTag = "3.4.1"

package `electron-builder-nsis-resources`:
  provisioning:
    tarball url = "https://github.com/electron-userland/electron-builder-binaries/releases/download/nsis-resources-" &
        ElectronBuilderNsisResourcesTag & "/nsis-resources-" &
        ElectronBuilderNsisResourcesTag & ".7z",
      sha256 = "593a9a92ef958321293ac6a2ee61e64bf1bd543142a5bd6b3d310709cc924103",
      archiveType = "7z",
      executablePath = "plugins/x86-unicode/nsis7z.dll",
      packageId = "electron-builder-nsis-resources@" &
        ElectronBuilderNsisResourcesTag,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:electron-builder-nsis-resources@" &
        ElectronBuilderNsisResourcesTag &
        ":windows-x86_64:sha256:593a9a92ef958321293ac6a2ee61e64bf1bd543142a5bd6b3d310709cc924103"
