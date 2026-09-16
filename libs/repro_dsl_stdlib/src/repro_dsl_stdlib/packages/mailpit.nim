## ``mailpit`` — the SMTP capture server Agent Harbor's email-channel tests
## send through.
##
## The suite's ``test_email_send_e2e_mailpit`` case SKIPS when no mailpit is
## reachable, which is the failure mode this package removes: a skipped test
## reports green while verifying nothing.
##
## Upstream zips carry the binary flat at the root.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const
  MailpitVersion = "1.30.1"
  MailpitBase = "https://github.com/axllent/mailpit/releases/download/v" &
    MailpitVersion & "/mailpit-windows-"

package mailpit:
  provisioning:
    nixPackage "nixpkgs#mailpit", executablePath = "bin/mailpit",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = MailpitBase & "amd64.zip",
      sha256 = "efe727d63b28361b47f6a81bf4054a03a77940178b9f67107928e6c1a483c34b",
      archiveType = "zip",
      executablePath = "mailpit.exe",
      packageId = "mailpit@" & MailpitVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:mailpit@" & MailpitVersion &
        ":windows-x86_64:sha256:efe727d63b28361b47f6a81bf4054a03a77940178b9f67107928e6c1a483c34b"

    tarball url = MailpitBase & "arm64.zip",
      sha256 = "2b6c5dd19e7fd07ecdd16b61869ed1a50b76430627778f72f23d3a6d738fdc0b",
      archiveType = "zip",
      executablePath = "mailpit.exe",
      packageId = "mailpit@" & MailpitVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:mailpit@" & MailpitVersion &
        ":windows-aarch64:sha256:2b6c5dd19e7fd07ecdd16b61869ed1a50b76430627778f72f23d3a6d738fdc0b"
