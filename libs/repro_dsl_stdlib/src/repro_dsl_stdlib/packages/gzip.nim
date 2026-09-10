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
