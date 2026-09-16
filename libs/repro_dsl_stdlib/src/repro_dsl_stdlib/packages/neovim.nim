## ``neovim`` — the editor Agent Harbor's TUI and PTY suites drive.
##
## Not a developer convenience here: the terminal-multiplexer and
## agent-activity tests launch a real editor inside a real PTY, so nvim is a
## test dependency and its absence turns those cases into silent skips.
##
## Upstream's Windows zips carry an ``nvim-win64/`` (or ``nvim-win-arm64/``)
## wrapper holding ``bin/nvim.exe`` plus the runtime tree; stripComponents=1
## flattens the wrapper while keeping ``bin/`` and ``share/`` adjacent, which
## is what lets nvim find its own runtime files.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const
  NeovimVersion = "0.11.6"
  NeovimBase = "https://github.com/neovim/neovim/releases/download/v" &
    NeovimVersion & "/"

package neovim:
  provisioning:
    nixPackage "nixpkgs#neovim", executablePath = "bin/nvim",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = NeovimBase & "nvim-win64.zip",
      sha256 = "90fc6d7cdf3d3388737caab1e2c554aa24b468f3a5cc38ef63857ddf1103513c",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/nvim.exe",
      packageId = "neovim@" & NeovimVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:neovim@" & NeovimVersion &
        ":windows-x86_64:sha256:90fc6d7cdf3d3388737caab1e2c554aa24b468f3a5cc38ef63857ddf1103513c"

    tarball url = NeovimBase & "nvim-win-arm64.zip",
      sha256 = "67a4e1da1f0d99e71c5e7b2dfd95f8c34721bd8c139eec99bb3e9034c2766301",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/nvim.exe",
      packageId = "neovim@" & NeovimVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:neovim@" & NeovimVersion &
        ":windows-aarch64:sha256:67a4e1da1f0d99e71c5e7b2dfd95f8c34721bd8c139eec99bb3e9034c2766301"
