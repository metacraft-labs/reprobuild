## Workspace resolution names the manifest data it found, not only the two
## things it did not find.
##
## THE DEFECT. When ``resolveWorkspaceProjectShared`` (and its sibling in
## ``repro workspace lock``) could name no project, it raised one sentence:
##
##   <op> requires either `.repro/workspace-state.toml` or a <project> argument;
##   neither was present at <root>
##
## The sentence names the two things that were ABSENT and says nothing about
## the thing that was PRESENT and decisive — membership manifest data
## (``projects/*.toml`` / ``variants/*.toml``) sitting at that very root.
##
## For the repository that hits this most often, BOTH remedies the sentence
## offers are wrong. That repository is a standalone or bare clone of the
## manifests repo — the LOCK RECORD STORE, ``metacraft-manifests`` in the
## field. It carries ``projects/``, ``repos/`` and ``locks/`` at its top
## level, no ``.repro/`` shell, and no committed ``repro.lock``. It holds the
## membership and lock records FOR a workspace and is not one. Hand-creating
## ``.repro/workspace.toml`` there would make the store CLAIM to be the
## workspace it describes — the route inference
## ``reprobuild-specs/Unified-Locking-And-Hooks.md`` §10 forbids, and §5
## records that the old ``manifests`` directory name already misled "at least
## one implementation path" into exactly that. Passing a ``<project>`` is the
## same mistake wearing an argument.
##
## WHICH ROOTS GET WHICH MESSAGE, AND WHY THIS SUITE HAS THREE ARMS. The fix
## must not be "replace the message"; two of the three shapes below still
## deserve the original sentence, and a fix that changed all three would pass a
## single-arm test while destroying the one distinction that matters.
##
##   Arm A — a STANDALONE BARE MANIFESTS CLONE. ``projects/``, ``repos/`` and
##     ``locks/`` at the top level, no ``.repro/`` anywhere, no committed
##     ``repro.lock``, not nested under any workspace. Neither remedy applies;
##     this arm must get the new, distinct diagnostic.
##
##   Arm B — a GENUINELY EMPTY root. A plain git repo with no manifest data,
##     no ``.repro/`` and no ``repro.lock``. Nothing was found at all and
##     creating a workspace really is the answer, so this arm must keep the
##     ORIGINAL sentence.
##
##   Arm C — a REAL WORKSPACE whose metadata has not been written yet: flat
##     ``projects/*.toml`` BESIDE a ``.repro/`` shell, no ``workspace.toml``.
##     The ``.repro/`` shell is the line ``hasResolvedManifestCheckout`` draws
##     between a workspace and the store it describes, and on this side of it
##     both original remedies are CORRECT — ``repro workspace init`` writes the
##     metadata, and ``<project>`` names a project that is genuinely there. So
##     this arm must keep the ORIGINAL sentence too.
##
##   Arm D — the ARM-A LISTING WITH A COMMITTED ``repro.lock`` at its root.
##     MO-2 makes that file a workspace marker in its own right
##     (``isInitializedWorkspace`` says so), so this root IS a workspace
##     however much its directory listing resembles the store, and it must
##     keep the ORIGINAL sentence — whose two remedies are both correct here.
##
##     It is also the only shape that can reach a raise with a ``repro.lock``
##     present, and so the only place the new diagnostic's "with no committed
##     `repro.lock` at <root>" clause can be a FALSE statement about the
##     filesystem. ``repro workspace sync`` cannot get there: its MO-9 ladder
##     runs the MO-2 fallback, which resolves this root FROM that very lock.
##     ``repro workspace lock``'s ladder carries no such fallback and never
##     reads the file, so it can, and a diagnostic keyed only on "manifest
##     data present, no `.repro/`" asserts there is no lock while one sits in
##     the directory it is naming. Only ``lock`` is driven here, because only
##     ``lock`` reaches it.
##
##     Arm C is also the guard against the obvious-looking implementation. The
##     committed-lock fallback is gated on ``not
##     hasResolvedManifestCheckout(root)``, which invites gating the new
##     diagnostic on that predicate being TRUE. That is backwards: after the
##     ``.repro/``-shell fix a bare manifests clone answers that predicate
##     FALSE (arm A) while a metadata-less real workspace answers it TRUE
##     (arm C). Gating on it would attach "this is not a workspace" to real
##     workspaces — and would flip the eight refusals
##     ``t_migrated_repo_workspace_real_pre_push.nim`` asserts, all of which
##     are arm-C-shaped.
##
## BOTH RAISE SITES. ``repro workspace sync`` reaches the shared ladder
## (``resolveWorkspaceProjectShared``); ``repro workspace lock`` has its own
## copy of the same dispatch and its own copy of the same sentence. Both are
## driven here, against arm A and against arm B, so neither can be fixed while
## the other keeps misdirecting.
##
## NO MOCKS. Every root here is a real git repo built by real ``git`` commands
## in a fresh tempdir; nothing stubs the filesystem or the git boundary, and
## the assertions are made on the real ``repro`` binary's real output.
## ``REPROBUILD_REPRO`` is pinned and the binary is invoked by absolute path
## for the reason ``t_hooks_noop_outside_initialized_workspace.nim``'s header
## records: a fixture that leaves it unset silently exercises whatever
## ``repro`` is on PATH (here: the pinned store build) instead of the build
## under test.
##
## Every invocation is read-only by construction — ``sync`` runs under
## ``--dry-run`` and both verbs fail in the resolver before any mutation.
##
## Skip rule: ``git`` missing on PATH (same convention as the RA-10 suite).

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support

# ---- helpers --------------------------------------------------------------

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  let candidate =
    if configured.len > 0: configured
    else: repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
  requireBinary(candidate, "reprobuild.apps.repro")

proc requireGit(gitBin: string; args: openArray[string]): string =
  var argv = @[gitBin]
  argv.add(args)
  let res = runShell(shellCommand(argv))
  if res.code != 0:
    checkpoint("git failed: " & argv.join(" ") & "\n" & res.output)
    quit 1
  res.output

proc seedRepo(gitBin, path: string) =
  ## A real git repo with one real commit, and nothing else.
  createDir(path)
  discard requireGit(gitBin, ["init", "-b", "main", path])
  discard requireGit(gitBin,
    ["-C", path, "config", "user.email", "tester@example.invalid"])
  discard requireGit(gitBin,
    ["-C", path, "config", "user.name", "Manifest Data Tester"])
  writeFile(path / "README.md", "fixture\n")
  discard requireGit(gitBin, ["-C", path, "add", "-A"])
  discard requireGit(gitBin, ["-C", path, "commit", "-m", "fixture"])

proc writeMembershipManifests(root: string) =
  ## The flat native membership layout a manifests repo carries at its top
  ## level: one resolved project and the repo fragment it includes.
  createDir(root / "projects")
  createDir(root / "repos")
  writeFile(root / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"origin\"\n" &
    "fetch = \"https://example.invalid/app.git\"\n\n" &
    "includes = [\"repos/app.toml\"]\n")
  writeFile(root / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"origin\"\nrevision = \"main\"\n")

proc runRepro(reproBin, cwd: string; args: openArray[string]):
    tuple[code: int; output: string] =
  ## Run the binary under test FROM the fixture root. ``--workspace-root`` is
  ## passed as well, so the cwd is belt and braces: it also keeps any
  ## cwd-based discovery from resolving out to whatever workspace the suite
  ## itself happens to be running inside.
  var argv = @[reproBin]
  argv.add(args)
  runShell(shellCommand(argv,
    @[(name: "REPROBUILD_REPRO", value: reproBin)]), cwd)

# The two sentences under test. ``originalRefusal`` is the text that must
# survive for arms B and C; ``storeRefusalMarkers`` are the facts the new
# diagnostic must carry for arm A — that manifest data was FOUND, where, that
# the shape is the record store / a bare manifests clone, and that it is not a
# workspace.
const
  originalRefusal = "requires either `.repro/workspace-state.toml`"
  storeRefusalMarkers = [
    "membership manifest data",
    "is not a workspace",
    "lock record store",
    "repro.lock",
  ]

proc checkStoreDiagnostic(label: string;
                          res: tuple[code: int; output: string];
                          root, manifestFile: string) =
  ## Arm A's contract: refused, with the DISTINCT diagnostic — and provably
  ## not merely the original sentence with extra words, since the original is
  ## asserted absent.
  if res.code == 0:
    checkpoint(label & ": expected a refusal, got exit 0\n" & res.output)
  check res.code != 0
  if originalRefusal in res.output:
    checkpoint(label & ": still the original sentence\n" & res.output)
  check originalRefusal notin res.output
  for marker in storeRefusalMarkers:
    if marker notin res.output:
      checkpoint(label & ": diagnostic never says '" & marker & "'\n" &
        res.output)
    check marker in res.output
  # Principle 2 — name the specific thing at fault: the root, and the manifest
  # file that proves the claim about it.
  check root in res.output
  check manifestFile in res.output

proc checkOriginalDiagnostic(label: string;
                             res: tuple[code: int; output: string];
                             root: string) =
  ## Arms B and C: refused with the ORIGINAL sentence, and provably not with
  ## arm A's, which would be a false "this is not a workspace" verdict.
  if res.code == 0:
    checkpoint(label & ": expected a refusal, got exit 0\n" & res.output)
  check res.code != 0
  if originalRefusal notin res.output:
    checkpoint(label & ": original sentence gone\n" & res.output)
  check originalRefusal in res.output
  check "is not a workspace" notin res.output
  check root in res.output

# ---- the suite ------------------------------------------------------------

suite "workspace resolution names the manifest data it found":

  test "t_workspace_resolution_names_the_manifest_data_it_found":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repo")
    else:
      let reproBin = reproBinary()
      putEnv("REPROBUILD_REPRO", reproBin)
      let scratch = createTempDir("repro-manifest-data-", "-fixture")
      defer: removeDir(scratch)

      # ========================================================
      # Arm A — a standalone BARE MANIFESTS CLONE / lock record store.
      # ========================================================
      let store = scratch / "manifests-store"
      seedRepo(gitBin, store)
      writeMembershipManifests(store)
      createDir(store / "locks")
      writeFile(store / "locks" / ".keep", "")
      discard requireGit(gitBin, ["-C", store, "add", "-A"])
      discard requireGit(gitBin,
        ["-C", store, "commit", "-m", "membership + records"])

      # The fixture is the shape the claim is about, asserted rather than
      # assumed: manifest data present, BOTH workspace markers absent, and no
      # ``.repro/`` shell at all.
      check fileExists(store / "projects" / "app.toml")
      check dirExists(store / "repos")
      check dirExists(store / "locks")
      check not dirExists(store / ".repro")
      check not fileExists(store / "repro.lock")
      # Nothing above it is a workspace either, so no upward resolution can
      # rescue this root (the shape the `agents` fix already handles).
      check not dirExists(scratch / ".repro")
      check not fileExists(scratch / "repro.lock")

      let storeManifest = store / "projects" / "app.toml"
      checkStoreDiagnostic("workspace sync(store)",
        runRepro(reproBin, store,
          ["workspace", "sync", "--workspace-root=" & store, "--dry-run"]),
        store, storeManifest)
      checkStoreDiagnostic("workspace lock(store)",
        runRepro(reproBin, store,
          ["workspace", "lock", "--workspace-root=" & store]),
        store, storeManifest)

      # Neither verb manufactured workspace state in the store on its way out.
      # An untracked ``.repro/`` beside the store's tracked files is dirt
      # outside ``locks/``, which is what the lock publisher's dirty guard
      # refuses, permanently.
      check not dirExists(store / ".repro")
      check not fileExists(store / "repro.lock")

      # ========================================================
      # Arm B — a GENUINELY EMPTY root: nothing was found, so creating a
      # workspace really is the remedy and the original sentence stands.
      # ========================================================
      let empty = scratch / "empty-repo"
      seedRepo(gitBin, empty)
      check not dirExists(empty / "projects")
      check not dirExists(empty / ".repro")
      check not fileExists(empty / "repro.lock")

      checkOriginalDiagnostic("workspace sync(empty)",
        runRepro(reproBin, empty,
          ["workspace", "sync", "--workspace-root=" & empty, "--dry-run"]),
        empty)
      checkOriginalDiagnostic("workspace lock(empty)",
        runRepro(reproBin, empty,
          ["workspace", "lock", "--workspace-root=" & empty]),
        empty)

      # ========================================================
      # Arm C — a REAL WORKSPACE with flat membership BESIDE a ``.repro/``
      # shell and no ``workspace.toml`` yet. Manifest data is at the root here
      # too, so this is the arm that proves the new diagnostic keys on the
      # ``.repro/`` shell and not merely on "manifest data is present".
      # ========================================================
      let workspace = scratch / "real-workspace"
      seedRepo(gitBin, workspace)
      writeMembershipManifests(workspace)
      createDir(workspace / ".repro")
      check dirExists(workspace / ".repro")
      check not fileExists(workspace / ".repro" / "workspace-state.toml") and
        not fileExists(workspace / ".repro" / "workspace.toml")
      check fileExists(workspace / "projects" / "app.toml")

      checkOriginalDiagnostic("workspace sync(workspace)",
        runRepro(reproBin, workspace,
          ["workspace", "sync", "--workspace-root=" & workspace,
           "--dry-run"]),
        workspace)
      checkOriginalDiagnostic("workspace lock(workspace)",
        runRepro(reproBin, workspace,
          ["workspace", "lock", "--workspace-root=" & workspace]),
        workspace)

      # …and the remedy that sentence offers is genuinely available here: the
      # named project resolves. (Falsification control for arm C's claim — if
      # this root were really "not a workspace", this would refuse too.)
      let named = runRepro(reproBin, workspace,
        ["workspace", "list", "--workspace-root=" & workspace, "app"])
      if named.code != 0:
        checkpoint("workspace list(workspace, app) output: " & named.output)
      check named.code == 0
      check "app" in named.output

      # ========================================================
      # Arm D — arm A's listing plus a committed ``repro.lock``. The MO-2
      # workspace marker outranks the store's shape, so the original sentence
      # stands; and the new diagnostic must never claim there is no committed
      # `repro.lock` at a root that has one.
      # ========================================================
      let lockedRoot = scratch / "locked-store-shape"
      seedRepo(gitBin, lockedRoot)
      writeMembershipManifests(lockedRoot)
      createDir(lockedRoot / "locks")
      writeFile(lockedRoot / "locks" / ".keep", "")
      # Content is deliberately minimal: MO-2's marker is the FILE's presence
      # (`hasCommittedLockWorkspaceMarker` is a bare `fileExists`), and the
      # `workspace lock` ladder raises before anything parses it. A fixture
      # that needed a well-formed lock would be testing the parser instead.
      writeFile(lockedRoot / "repro.lock",
        "schema = \"reprobuild.lock.v2\"\n")
      discard requireGit(gitBin, ["-C", lockedRoot, "add", "-A"])
      discard requireGit(gitBin,
        ["-C", lockedRoot, "commit", "-m", "membership + committed lock"])
      check fileExists(lockedRoot / "repro.lock")
      check fileExists(lockedRoot / "projects" / "app.toml")
      check not dirExists(lockedRoot / ".repro")

      checkOriginalDiagnostic("workspace lock(committed-lock root)",
        runRepro(reproBin, lockedRoot,
          ["workspace", "lock", "--workspace-root=" & lockedRoot]),
        lockedRoot)
      # The clause the arm exists for, asserted directly: whatever this
      # refusal says, it must not announce the absence of the file above.
      let lockedOut = runRepro(reproBin, lockedRoot,
        ["workspace", "lock", "--workspace-root=" & lockedRoot]).output
      check "no committed `repro.lock`" notin lockedOut
