## ``piper`` — the local neural text-to-speech engine Agent Harbor's voice
## backends use.
##
## Local by design: the voice path must work without sending audio to a
## hosted service, so the engine is a packaged dependency rather than an API
## client.
##
## The archive carries a ``piper/`` wrapper holding the executable plus the
## ONNX runtime DLLs and espeak-ng data it loads relative to itself;
## stripComponents=1 flattens the wrapper and keeps them adjacent.
##
## The version is upstream's date-stamped release tag, not a semver.

import repro_project_dsl

const PiperVersion = "2023.11.14-2"

package piper:
  provisioning:
    tarball url = "https://github.com/rhasspy/piper/releases/download/" &
        PiperVersion & "/piper_windows_amd64.zip",
      sha256 = "f3c58906402b24f3a96d92145f58acba6d86c9b5db896d207f78dc80811efcea",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "piper.exe",
      packageId = "piper@" & PiperVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:piper@" & PiperVersion &
        ":windows-x86_64:sha256:f3c58906402b24f3a96d92145f58acba6d86c9b5db896d207f78dc80811efcea"
