## Every tool the helper-list edge runs is declared, and declared only as a
## BUILD-HOST (`nativeBuildDeps:`) dependency of reprobuild's own recipe
## (ReproOS Add-On Mode spec §13 decision 74, amended round 8; reprobuild-pm
## issue 2026-11-08-helper-list-edge-strace-is-a-target-dependency-taken-
## from-the-host-path).
##
## The edge `reprobuild.helper-deps.repro-binary-cache` (target
## `.#repro-binary-cache-deps`) runs scripts/write_helper_deps.sh, which
## traces the Nim compiler with strace. A tool the build RUNS belongs in
## `nativeBuildDeps:`: under `--target` a `uses:` entry is a TARGET
## dependency, realized for the target machine (repro.nim's own note at
## `nativeBuildDeps:`, ReproOS-Add-On-Mode A15). strace was declared in
## `uses:`, so the recipe asked for a target-machine strace to run on the
## build host.
##
## Black box over the real recipe: the tree's engine (`build/bin/repro`)
## runs `repro build .#repro-binary-cache-deps --dry-run` in a scratch copy
## of the working tree (tracked files with their uncommitted changes, via
## `git stash create`), outside any workspace. The test then reads what
## that run wrote: the lowered edge's `toolIdentityRefs` (what it runs) and
## the extracted project interface's tool uses with their `depKind`. For
## each tool the edge runs, at least one use must declare it, and every use
## that does must be `native`. A cross build cannot be the observable here:
## `repro build --target=...` of this recipe stops earlier, at `nim.c`,
## which does not thread a cross target.
##
## Falsifier: move `"strace"` back from `nativeBuildDeps:` to the Linux
## block of `uses:` in repro.nim. The edge still names strace, its one use
## is then `target`, and the case is red.
##
## Linux only: the edge exists only there. The dry run needs the dev
## shell's tools on PATH, as every test of this suite does.
##
## Mocks: none -- the real engine, the real recipe, the real extraction.

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]
import repro_cli_support
import repro_interface_artifacts
import repro_provider_runtime
import repro_test_support
import repro_test_support/reasoned_skip
import repro_tool_profiles

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
  EdgeTarget = "repro-binary-cache-deps"

suite "the helper-list edge runs only build-host tools":
  test "every tool the edge names is a nativeBuildDeps entry, strace included":
    when not defined(linux):
      skip("Linux only: the helper-list edge exists only there")
    else:
      let reproBin = requireBinary(reproBinaryPath(RepoRoot),
        "reprobuild.apps.repro")
      let base = createTempDir("helper-list-edge-tools-", "")
      defer: removeDir(base)
      let copy = base / "reprobuild"
      createDir(copy)
      # The working tree, not HEAD: `git stash create` makes a commit of the
      # tracked files as they are, without touching the index or the stash
      # list, and prints nothing when the tree is clean.
      let (stashOut, stashCode) = execCmdEx("git -C " & quoteShell(RepoRoot) &
        " stash create")
      require stashCode == 0
      let rev = if stashOut.strip.len > 0: stashOut.strip else: "HEAD"
      let (archiveOut, archiveCode) = execCmdEx("git -C " &
        quoteShell(RepoRoot) & " archive " & quoteShell(rev) & " | tar -x -C " &
        quoteShell(copy))
      checkpoint archiveOut
      require archiveCode == 0

      let reportPath = base / "report.json"
      discard requireSuccess(shellCommand([reproBin, "build",
        ".#" & EdgeTarget, "--dry-run", "--daemon=off",
        "--write-report=" & reportPath, "--progress=quiet"]), copy)
      require fileExists(reportPath)
      let report = parseFile(reportPath)
      let metadataRoot = report["providerSnapshot"].getStr.parentDir.parentDir
      let snapshot = loadProviderGraphSnapshot(metadataRoot / "provider-graph")
      let identity = readPathOnlyBuildIdentity(
        metadataRoot / "path-only-tool-identities.rbtp")
      let lowered = lowerProviderSnapshot(snapshot, identity, copy, EdgeTarget)
      let edge = lowered.actions.filterIt(it.id == EdgeTarget)
      require edge.len == 1
      let refs = edge[0].toolIdentityRefs
      checkpoint "edge tools: " & refs.join(" ")
      # The writer's tracer; the case would prove nothing if the edge no
      # longer named it.
      require "strace" in refs

      let iface = readInterfaceArtifact(metadataRoot / "project-interface.rbsz")
      for name in refs:
        let uses = iface.projectInterface.toolUses.filterIt(
          it.executableName == name)
        checkpoint name & ": " & uses.mapIt(
          "\"" & it.rawConstraint & "\" depKind=" & it.depKind).join(", ")
        check uses.len > 0
        check uses.allIt(it.depKind == "native")
