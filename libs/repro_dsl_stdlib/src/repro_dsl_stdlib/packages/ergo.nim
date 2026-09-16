## ``ergo`` — the IRC server Agent Harbor's chat-channel tests run against.
##
## Like mailpit, this exists so a test EXERCISES the protocol instead of
## skipping for want of a server.
##
## The archive carries an ``ergo-<version>-windows-x86_64/`` wrapper holding
## the binary plus its default config and language files, which ergo reads
## relative to itself — so stripComponents=1 flattens the wrapper and keeps
## those siblings, rather than isolating the binary from them.
##
## x86_64 only: upstream publishes no arm64 Windows build for this release.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const ErgoVersion = "2.18.0"

package ergo:
  provisioning:
    nixPackage "nixpkgs#ergochat", executablePath = "bin/ergo",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = "https://github.com/ergochat/ergo/releases/download/v" &
        ErgoVersion & "/ergo-" & ErgoVersion & "-windows-x86_64.zip",
      sha256 = "c38893560d32544ddb2701c7e4df3e185ed0221bb1df4a955122c9eebd16c296",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "ergo.exe",
      packageId = "ergo@" & ErgoVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:ergo@" & ErgoVersion &
        ":windows-x86_64:sha256:c38893560d32544ddb2701c7e4df3e185ed0221bb1df4a955122c9eebd16c296"
