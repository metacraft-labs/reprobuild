## ``piper-voice-lessac-medium-config`` — the JSON half of the Lessac voice.
##
## The other half of ``piper-voice-lessac-medium``; see that module for why a
## Piper voice is two packages and why both must be declared together. This
## file carries the sample rate, the phoneme inventory and the speaker map
## the runtime needs in order to drive the ONNX graph, so the two are pinned
## at the same upstream revision and a consumer that declares one without the
## other has a voice that cannot be loaded.
##
## ``archiveType = "raw"``, and ``.json`` was already a recognised data
## extension.

import repro_project_dsl

import repro_dsl_stdlib/packages/piper_voice_lessac_medium

const
  PiperVoiceLessacMediumConfigFileName* = "en_US-lessac-medium.onnx.json"
  PiperVoiceLessacMediumConfigSha256* =
    "efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0"
    ## Harvested from Agent Harbor's ``scripts/provision-voice-local-models.py``.

package `piper-voice-lessac-medium-config`:
  provisioning:
    tarball url = PiperVoiceLessacMediumBaseUrl &
        PiperVoiceLessacMediumConfigFileName,
      sha256 = PiperVoiceLessacMediumConfigSha256,
      archiveType = "raw",
      executablePath = PiperVoiceLessacMediumConfigFileName,
      packageId = "piper-voice-lessac-medium-config@" &
        PiperVoiceLessacMediumRevision,
      lockIdentity = "tarball:piper-voice-lessac-medium-config@" &
        PiperVoiceLessacMediumRevision & ":sha256:" &
        PiperVoiceLessacMediumConfigSha256
