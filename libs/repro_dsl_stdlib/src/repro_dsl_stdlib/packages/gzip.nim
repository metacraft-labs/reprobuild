## ``gzip`` — the compressor GNU ``tar -z`` actually runs.
##
## This package exists because of a failure that only a REAL build could
## produce. ``tar -z`` does not compress anything itself: it forks and
## execs a program called ``gzip`` found on ``PATH``. An action's PATH in
## reprobuild is composed only of the tools the graph resolved FOR THAT
## EDGE, so the tarball producer's action — which named ``tar`` and
## nothing else — got gnutar's bin directory and no gzip, and the first
## Linux execution of ``tarballPackage`` died with::
##
##   sh: line 1: gzip: command not found
##   tar: build/dist/…tar.gz: Wrote only 4096 of 10240 bytes
##   tar: Child returned status 127
##
## The unit cases could not see it: they read the argv the producer
## built and the tool the edge named, and both were correct. What was
## missing was a tool the NAMED tool goes on to exec — a dependency that
## is invisible in the producer's own source and shows up only when the
## action runs under a hermetic PATH.
##
## Distribution-And-Packaging.md §6 rule 1 ("packaging tools are
## reprobuild packages … no producer shells out to an assumed-present
## host tool") therefore has to reach one level further than the tool a
## producer types. Declaring gzip here, and naming it on the tarball
## edge (``producers/tarball.nim``'s ``GzipSelector``), is that rule
## applied to tar's own child process.
##
## **Provisioning-only, no ``executable`` block.** Nothing in the layer
## invokes gzip through a typed CLI — ``tar`` does, by name, behind our
## back. The package's whole job is to satisfy the resolver so that
## gzip's bin directory joins the tar action's PATH, which is the same
## job ``packages/zstd.nim`` does for the Windows recorder path.
##
## **No Windows channel, deliberately.** The tarball producer is a POSIX
## path (its staging emits ``install``-mode edges and ``$ORIGIN``
## RPATHs); per §6.1 an unavailable format is just an unresolvable tool
## dependency, never a switch in the engine.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package gzip:
  provisioning:
    nixPackage "nixpkgs#gzip", executablePath = "bin/gzip",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # WINDOWS: GNU gzip 1.14, from the same archive. ``tar -z`` execs a
    # program called ``gzip`` off the PATH, so the compressor has to be
    # resolvable on the tar action's edge on every target, not only on
    # the one where the walk found it first.
    #
    # The SAME PortableGit archive ``packages/sh.nim`` and
    # ``packages/bash.nim`` already pin by sha256 -- one archive,
    # one ``packageId``, one ``lockIdentity``, three more
    # ``executablePath`` views of it. Nothing new is downloaded and
    # no new lock-identity family appears in ``repro.lock``.
    #
    # WHY A CHANNEL IS NEEDED AT ALL when Win11 ships ``tar.exe`` in
    # System32: tool provisioning is ONE MODE FOR THE WHOLE BUILD.
    # A Windows build that needs the WiX tools must run
    # ``--tool-provisioning=tarball``, and in that mode a package
    # with no tarball channel is a hard refusal -- which is why the
    # dogfood recipe's Windows arm stopped emitting the
    # Scoop/tarball pair (M1's N20), and why Linux could not run
    # that mode either and the AppImage build had to fall back to
    # ``--tool-provisioning=path``. THIS CHANNEL ANSWERS ONLY THE
    # WINDOWS HALF, and the distinction is the whole of M1's N20
    # correction: the entry is declared ``os = "windows"``, so a
    # Linux host in tarball mode still refuses, in one line --
    # ``no tarball provisioning entry for package "tar" matches
    # host cpu=x86_64 os=linux (1 entries)``. Answering Linux means
    # pinning LINUX tarballs for GNU tar, gzip and coreutils --
    # three new downloads to vet, which is a decision for whoever
    # owns the provisioning catalogue rather than a typo here.
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/gzip.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"
