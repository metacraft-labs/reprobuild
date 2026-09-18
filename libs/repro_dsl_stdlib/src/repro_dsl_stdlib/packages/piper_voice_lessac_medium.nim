## ``piper-voice-lessac-medium`` — a Piper TTS voice, as a package.
##
## A Piper voice is two files that must agree: an ONNX graph and a JSON
## config describing its sample rate, phoneme inventory and speaker map. The
## runtime reads the config to drive the graph, so a mismatched pair is not a
## degraded voice, it is a crash or noise.
##
## They live at two upstream URLs, and reprobuild's tarball provisioning is
## one URL per package, so they are two packages — ``piper-voice-lessac-medium``
## here and ``piper-voice-lessac-medium-config`` beside it. A consumer must
## declare BOTH; neither is useful alone. They are pinned to the same upstream
## revision for that reason, and this is the same shape the MSYS2 ``tmux``
## group uses: packages that have to be declared together because the thing
## they make possible needs all of them on disk.
##
## The *engine* that consumes this voice is ``piper``, which is a separate
## package for the ordinary reason — it is a program, and it is per-platform,
## and neither of those is true of the voice.
##
## ``archiveType = "raw"``: the ``.onnx`` is the payload, not an archive. It
## is weights, so ``dataExts`` covers ``.onnx`` and nothing checks it for an
## executable bit. Platform-independent for the same reason
## ``whisper-ggml-base`` is: the bytes do not vary by host.

import repro_project_dsl

const
  PiperVoiceLessacMediumRevision* = "main"
    ## As with the Whisper weights: the digest is the pin, and the moving
    ## ref fails loudly rather than quietly if upstream republishes.
  PiperVoiceLessacMediumBaseUrl* =
    "https://huggingface.co/rhasspy/piper-voices/resolve/" &
    PiperVoiceLessacMediumRevision & "/en/en_US/lessac/medium/"
  PiperVoiceLessacMediumFileName* = "en_US-lessac-medium.onnx"
  PiperVoiceLessacMediumSha256* =
    "5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f"
    ## Harvested from Agent Harbor's ``scripts/provision-voice-local-models.py``.

package `piper-voice-lessac-medium`:
  provisioning:
    tarball url = PiperVoiceLessacMediumBaseUrl &
        PiperVoiceLessacMediumFileName,
      sha256 = PiperVoiceLessacMediumSha256,
      archiveType = "raw",
      executablePath = PiperVoiceLessacMediumFileName,
      packageId = "piper-voice-lessac-medium@" &
        PiperVoiceLessacMediumRevision,
      lockIdentity = "tarball:piper-voice-lessac-medium@" &
        PiperVoiceLessacMediumRevision & ":sha256:" &
        PiperVoiceLessacMediumSha256
