## Unified-Locking-And-Hooks.md §13.1 — the in-tree row of the backend table,
## asserted for `repro.lock` itself.
##
## ## The claim under test, and why nothing was holding it
##
## §13.1 makes the lock UPDATE RULE a property of the BACKEND rather than a
## global rule:
##
##   | out-of-tree (git-checkout, git-notes, …) | the PRE-PUSH GATE writes it |
##   | in-tree (committed-file)                 | the PRE-COMMIT hook writes  |
##   |                                          | it; pre-push VERIFIES ONLY  |
##
## and gives the reason the second row cannot be the first: "the gate writes
## `repro.lock` — the working tree is now dirty; the dirt must be committed —
## HEAD moves; the lock now describes the tree as it stood *before* the commit
## that carries it… There is no ordering that closes this loop, because the
## artifact is part of the state it records."
##
## `flake.lock` has this pinned at both ends (NF-2 writes it at `pre-commit`,
## NF-3's stage verifies it at `pre-push`). `repro.lock` — the committed
## solved-graph lock, and the artifact §13.1's rule is NAMED after — had
## nothing. The closest existing case,
## `t_pre_push_public_only_writes_no_manifest_lock`, asserts that the gate
## writes no lock under a store the workspace never declared; it says nothing
## about the lock the repo DOES carry. So "the gate leaves `repro.lock` alone"
## was true, documented, and entirely untested.
##
## That gap is not academic. It was read the other way round in this very
## file: a comment on the post-commit path asserted that "everything below
## writes `repro.lock` into the working tree" and that "the pre-push gate
## refreshes it before anything is published" — both true of the OUT-OF-TREE
## SHA-keyed record that proc actually writes, both false of `repro.lock`. A
## gate that quietly started refreshing the committed lock would have
## satisfied every test in the suite.
##
## ## The fixture pins a SIBLING, and that is not incidental
##
## §13.5 states the contract the gate acquires once it has stopped producing:
## "refuse when the committed lock's pins do not match the observable
## siblings". For a PASS to be the unambiguously correct verdict — now, and
## still after §13.5 is implemented — the fixture's lock must be one §13.5 has
## no quarrel with. So `lib-a`'s committed lock pins `lib-b` at `lib-b`'s
## actual `HEAD`, and nothing else.
##
## A lock pinning its OWN repo cannot be made to agree: the pin would have to
## name the commit that carries it. The first draft of this fixture tried
## (write a placeholder, commit, rewrite at the real SHA, amend) and produced
## a lock pinning the pre-amend commit — orphaned by the amend, so the gate
## reported it `unreachable` and the fixture asserted a PASS over a lock that
## was, by §13.5's standard, exactly the thing that should be refused. That
## self-reference is §13.1's argument, reproduced by accident; the sibling
## shape is the one that sidesteps it, which is also why every real committed
## lock in this workspace pins its own repo at a revision behind `HEAD`.
##
## ## What is asserted
##
##   1. the gate PASSES;
##   2. `repro.lock` is BYTE-IDENTICAL afterwards;
##   3. it was not WRITTEN at all — mtime unchanged. A rewrite with identical
##      bytes is still a write, and "the bytes match" is not the same claim as
##      "nothing wrote it";
##   4. the working tree is CLEAN afterwards. This is the assertion that
##      speaks to §13.1's actual argument: the failure mode is not a wrong
##      lock, it is a dirty tree at the exact moment the gate's own first
##      stage demands a clean one.
##
## ## Falsifiability (measured, not asserted)
##
## Mutation applied: the WEAKEST possible violation of the in-tree row — at
## the head of stage 4, `writeFile(currentRepo / "repro.lock",
## readFile(currentRepo / "repro.lock"))`. Identical bytes, so (2) and (4)
## stay green and only (3) can see it. Result: RED on (3)
## (`getLastModificationTime(lockPath) == beforeMtime` failed) with the gate
## still reporting `repro check: OK`. A real refresh — reaching
## `runLockGenerationVerb` with `committedLockPath(currentRepo)` — also moves
## (2) and (4), since the regenerated document carries a recomputed
## `inputs_digest` and the host's own `platform`, neither of which matches the
## fixture's.
##
## ## Test-double policy
##
## NO mocks, doubles or fakes. A real hermetic workspace on the real
## filesystem, real bare origins, real `git`, and the real `build/bin/repro`.
## The one thing written by hand rather than produced by a tool is the
## committed lock itself, and that is the point of the fixture: it is the
## artifact whose survival is under test, so it must be recognisably the
## operator's bytes and not something the binary just emitted.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, times, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
depends = ["lib-b"]
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

proc projectToml(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n"

proc committedLockToml(libBUrl, libBHead: string): string =
  ## A well-formed `reprobuild.solved-graph-lock.v2` whose single dep is the
  ## SIBLING, pinned at the revision that sibling is actually on — the one
  ## shape §13.5 has nothing to say about. `platform` is deliberately a value
  ## this host is not, so a regeneration cannot accidentally reproduce these
  ## bytes.
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"amd64-windows\"\n" &
  "optimal = false\n" &
  "inputs_digest = \"fnv1a64:0000000000000001\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"lib-b\", path = \"lib-b\", coord_kind = \"vcs\", url = \"" &
  libBUrl & "\", ref = \"main\", revision = \"" & libBHead &
  "\", integrity = \"git-sha1:" & libBHead &
  "\", version = \"\", visibility = \"public\", participation = \"\", " &
  "depends = \"\", tags = \"\" }]\n"

proc seedPublishedRepo(gitBin, origin, seed, marker: string): string =
  ## A bare origin plus a seed checkout with one published commit. Returns the
  ## published HEAD.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
  discard requireGit(q(gitBin) & " init -b main " & q(seed))
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.name \"Committed Lock Tester\"")
  writeFile(seed / "README.md", marker & "\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " remote add origin " &
    q(origin))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(seed) & " rev-parse HEAD").strip()

suite "pre-push — the committed `repro.lock` is verified, never rewritten":
  let gitBin = findExe("git")

  test "t_pre_push_verifies_the_committed_lock_and_never_rewrites_it":
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real bare origins and two real " &
        "clones for the gate to observe")
    else:
      let scratch = createTempDir("repro-committed-lock-untouched-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let originB = scratch / "origin-lib-b.git"
      let libBHead = seedPublishedRepo(gitBin, originB, scratch / "seed-lib-b",
        "sibling fixture")
      let originA = scratch / "origin-lib-a.git"
      discard seedPublishedRepo(gitBin, originA, scratch / "seed-lib-a",
        "pushed fixture")

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let manifestsRoot = workspaceRoot / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "lib-a.toml",
        projectToml(fileUrl(originA), fileUrl(originB)))
      writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
      writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)

      let libA = workspaceRoot / "lib-a"
      let libB = workspaceRoot / "lib-b"
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(originA)) & " " &
        q(libA))
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(originB)) & " " &
        q(libB))
      discard requireGit(q(gitBin) & " -C " & q(libA) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(libA) &
        " config user.name \"Committed Lock Tester\"")

      # The committed lock is part of a published commit of lib-a, and its one
      # pin names lib-b at the revision lib-b is checked out on.
      writeFile(libA / "repro.lock",
        committedLockToml(fileUrl(originB), libBHead))
      discard requireGit(q(gitBin) & " -C " & q(libA) & " add repro.lock")
      discard requireGit(q(gitBin) & " -C " & q(libA) & " commit -m lock")
      discard requireGit(q(gitBin) & " -C " & q(libA) & " push origin main")

      writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

      let lockPath = libA / "repro.lock"
      let before = readFile(lockPath)
      let beforeMtime = getLastModificationTime(lockPath)
      # The tree must be clean going in, or assertion (4) proves nothing.
      check requireGit(q(gitBin) & " -C " & q(libA) &
        " status --porcelain").strip() == ""

      let res = runCmd(q(reproBin) & " check --mode=pre-push" &
        " --workspace-root=" & q(workspaceRoot) &
        " --current-repo=" & q(libA))

      # (1) the gate reaches a verdict, and the verdict is PASS. The pin
      # agrees with the observable sibling, so this stays correct under §13.5.
      checkpoint("gate output:\n" & res.output)
      check res.code == 0
      # ...and it did not merely pass — it had nothing to say about this lock.
      # A coherence complaint here would mean the fixture's pin disagrees with
      # the checkout after all, which would make (1) prove the wrong thing.
      check "needing attention" notin res.output

      # (2) the committed lock is byte-identical.
      check readFile(lockPath) == before

      # (3) and was not written at all, identical bytes or otherwise.
      check getLastModificationTime(lockPath) == beforeMtime

      # (4) §13.1's actual argument: the gate did not dirty the tree whose
      # cleanliness its own first stage requires.
      check requireGit(q(gitBin) & " -C " & q(libA) &
        " status --porcelain").strip() == ""
