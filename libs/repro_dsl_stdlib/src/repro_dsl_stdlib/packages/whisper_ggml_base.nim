## ``whisper-ggml-base`` — the Whisper *base* model weights, as a package.
##
## ## Why model weights are a package
##
## A desktop installer that ships offline speech-to-text has to put the
## weights in the installer. The usual way that happens is a provisioning
## script run as a build step, which downloads the blob into the tree that
## the packager then sweeps up. That is an unpinned-in-practice network
## fetch inside a build: it succeeds on any machine with a network, so it is
## invisible until the build runs somewhere without one — a CI job on an
## isolated runner, a release rebuild, a contributor on a plane — and then it
## fails at packaging time rather than at dependency-resolution time, which
## is the wrong end of the build to discover a missing input.
##
## The weights are exactly what content addressing is for: a large, immutable
## blob with a stable digest that many builds share. Declaring them makes the
## download happen once per machine, land in the shared binary cache with
## everything else, and be *substitutable* — a second machine copies it from
## the cache instead of from Hugging Face.
##
## ## ``archiveType = "raw"``
##
## ``ggml-base.bin`` is not an archive; it is the payload. The ``raw``
## extractor copies the downloaded file into the prefix under the name
## ``executablePath`` declares, which is the whole realization.
##
## It is data, not a program — nothing execs a model file, a runtime
## memory-maps it — so the realizer's data-extension rule covers ``.bin`` and
## the executable-bit check is skipped. See ``repro_tool_profiles``'
## ``dataExts``.
##
## ## Platform-independent, deliberately
##
## No ``cpu`` or ``os``: the same bytes are correct on every host, and an
## empty platform is the catch-all the selector documents. The *runtime* that
## reads these weights is platform-specific and is a different package.

import repro_project_dsl

const
  WhisperGgmlBaseRevision* = "main"
    ## Hugging Face serves ``resolve/main``, which is a moving ref. The
    ## sha256 below is what actually pins this: a moving ref behind a fixed
    ## digest is a pin that BREAKS visibly if upstream republishes, rather
    ## than one that silently changes the bytes. The alternative — a commit
    ## sha in the URL — is preferable where upstream offers one; this
    ## repository does not expose the weights under an immutable path.
  WhisperGgmlBaseFileName* = "ggml-base.bin"
  WhisperGgmlBaseSha256* =
    "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
    ## Harvested from Agent Harbor's ``scripts/provision-voice-local-models.py``,
    ## which carried this digest for the same asset before the weights were
    ## packaged.

package `whisper-ggml-base`:
  provisioning:
    tarball url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/" &
        WhisperGgmlBaseRevision & "/" & WhisperGgmlBaseFileName,
      sha256 = WhisperGgmlBaseSha256,
      archiveType = "raw",
      executablePath = WhisperGgmlBaseFileName,
      packageId = "whisper-ggml-base@" & WhisperGgmlBaseRevision,
      lockIdentity = "tarball:whisper-ggml-base@" & WhisperGgmlBaseRevision &
        ":sha256:" & WhisperGgmlBaseSha256
