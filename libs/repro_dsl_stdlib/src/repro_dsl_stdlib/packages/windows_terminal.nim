## ``windows-terminal`` — the terminal host Agent Harbor's Windows TUI and
## desktop-automation suites drive.
##
## Windows-only by construction: the package declares no other platform,
## because there is no other platform for it to have.
##
## The release zip carries a ``terminal-<version>/`` wrapper holding
## ``wt.exe`` beside the fonts, the XAML assemblies and ``defaults.json``
## that the terminal loads relative to itself — so stripComponents=1 flattens
## the wrapper and keeps those siblings, rather than isolating the executable
## from the resources it needs to start.
##
## Verified by listing the archive rather than assumed: the first attempt
## declared no strip on the guess that the layout was flat, and the realize
## step refused with "extracted tarball lacks executable wt.exe" — the right
## failure, and the reason to read an archive before pinning its shape.

import repro_project_dsl

const
  WindowsTerminalVersion = "1.23.20211.0"
  WindowsTerminalBase =
    "https://github.com/microsoft/terminal/releases/download/v" &
    WindowsTerminalVersion & "/Microsoft.WindowsTerminal_" &
    WindowsTerminalVersion & "_"

package `windows-terminal`:
  provisioning:
    tarball url = WindowsTerminalBase & "x64.zip",
      sha256 = "83efe4572599479e9df38317a7be7feb1e2e86430432fc8d84f76df19de6cd11",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "wt.exe",
      packageId = "windows-terminal@" & WindowsTerminalVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:windows-terminal@" & WindowsTerminalVersion &
        ":windows-x86_64:sha256:83efe4572599479e9df38317a7be7feb1e2e86430432fc8d84f76df19de6cd11"

    tarball url = WindowsTerminalBase & "arm64.zip",
      sha256 = "22104751156d177632e9d11f2c3a93128c69c6507408ce97cefc837c22b4736c",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "wt.exe",
      packageId = "windows-terminal@" & WindowsTerminalVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:windows-terminal@" & WindowsTerminalVersion &
        ":windows-aarch64:sha256:22104751156d177632e9d11f2c3a93128c69c6507408ce97cefc837c22b4736c"
