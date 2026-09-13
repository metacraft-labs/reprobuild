## GNU coreutils `mktemp` — provisioning, a minimal CLI surface, and the
## ENTROPY BLESSING this file exists for.
##
## WHY A PACKAGE FOR A TOOL ALMOST NOBODY CALLS FROM A RECIPE. `mktemp` is the
## single largest emitter of `mrNonDeterministic` records in reprobuild's own
## consumers: across CodeTracer's ten `bash <script>` gate edges it accounts
## for 23 of 45, every one `path=getrandom`. None of them is emitted by the
## shell -- the shell emits none of its own -- so before per-image attribution
## existed there was nowhere to put the statement "this randomness is benign"
## except on the SHELL, where it would have waived every other program the
## script happened to run. `packages/sh.nim` refuses to carry it for that
## reason and says so at length. This file is the place that statement
## actually belongs: on the tool that drew the bytes.
##
## The blessing reaches the engine through
## `repro_core/entropy_blessings.EntropyBlessedTools`, keyed by the image name
## an `mrProcessExec` record carries; the declaration below is the authority
## and `libs/repro_dsl_stdlib/tests/t_entropy_image_blessings.nim` asserts the
## two carry the same text.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package mktemp:
  provisioning:
    # `mktemp` is a coreutils applet, so the package selector resolves the
    # coreutils derivation and exposes the one applet this package names.
    nixPackage "nixpkgs#coreutils", executablePath = "bin/mktemp",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: the MSYS coreutils that ship inside Git for Windows
    # (PortableGit) put the same applet at `usr/bin/mktemp.exe`. Resolving the
    # selector via Scoop installs `main/git` and exposes that tree on PATH.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/mktemp.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/mktemp.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

  executable mktemp:
    cli:
      dependencyPolicy automaticMonitor

      # THE ENTROPY BLESSING, declared here, on the tool, once -- the shape
      # `packages/nim.nim` established. Scoped to ENTROPY
      # (`mrNonDeterministic`), saying nothing about clock reads
      # (`mrTimeRead`), and nothing about the file, library-load, ipc or
      # external-content evidence that decides whether a capture is complete.
      #
      # READ THE LAST SENTENCE OF THE JUSTIFICATION BEFORE REACHING FOR THIS
      # SHAPE ELSEWHERE. mktemp is not `nim`: nim's random names never leave
      # nim, while mktemp PRINTS its name to stdout and hands it to the
      # caller. What makes the blessing sound is not that the bytes are
      # invisible but what they DESIGNATE -- a location under $TMPDIR, whose
      # contract is that it does not outlive the caller. `uuidgen` looks
      # identical in the evidence (one `getrandom`, one process, one pid) and
      # is deliberately NOT blessed, because the bytes it prints are the
      # product its caller keeps. That pair is what the per-image mechanism
      # exists to tell apart; see
      # `libs/repro_build_engine/tests/test_m6_entropy_image_attribution.nim`.
      nonDeterminism entropyBlessed,
        justification = "GNU coreutils `mktemp` draws randomness for " &
          "exactly one purpose: the X-suffix of the temporary name it " &
          "creates and prints. That name is a handle to scratch space whose " &
          "whole contract is that it does not outlive the caller, so the " &
          "random bytes designate a LOCATION and never the content of a " &
          "product. Measured with io-mon @87143d62 on the " &
          "linux-preload-hooks backend: across CodeTracer's ten shell gates " &
          "at 996f9b12 mktemp accounts for 23 of the 45 mrNonDeterministic " &
          "records, every one path=getrandom, every one emitted in a pid " &
          "whose mrProcessExec names mktemp and whose only writes are the " &
          "scratch directory the gate later removes; not one of those names " &
          "appears in a declared output. This blesses ENTROPY only. It says " &
          "nothing about a recipe that captures the printed name INTO a " &
          "product -- that is the recipe's bug, and a signal that records " &
          "zero events for a script whose whole output is $RANDOM was never " &
          "what guarded against it."

      call:
        # A deliberately minimal surface. Typed flags for `-d`, `-p`, `-u`
        # and the `XXXXXX` template are a separate piece of work; what this
        # edge exists to do is give the blessing above somewhere to attach
        # and a shape the correspondence test can read it off. Kept identical
        # to `packages/git.nim`'s for the same reason.
        pos args is seq[string],
          position = 0,
          required = false
