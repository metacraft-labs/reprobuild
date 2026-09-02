## A declared checkout path is a directory BENEATH the workspace root, and
## nothing downstream has to take that on trust.
##
## Why this matters more than it looks. Every consumer turns a declared path
## into `<workspaceRoot> / <path>`, and several of them delete the directory
## they compute: a half-finished clone is cleaned up by removing its target, a
## checkout that dies mid-filter is discarded the same way, and disabling a
## project removes the trees only it declared. All of that is correct exactly
## as long as the computed directory is the repo's own tree. Given
## `path = "."` the identical line computes the WORKSPACE ROOT; given
## `path = "../x"` it computes a sibling. So a degenerate value here is not a
## bad checkout — it is an unbounded recursive delete somewhere else on the
## disk, arriving through the recovery paths, which are the ones nobody
## exercises by hand.
##
## It is the same shape as the remote-alignment defect fixed alongside this:
## unrepresentable in a hand-written manifest, entirely reachable from a
## generator or a resolver bug. The guard used to live in ONE place, immediately
## in front of one `removeDir` inside `workspace disable`. That is the wrong
## altitude — it protects one call site and leaves every other one exposed,
## which is how a guard that exists still fails to hold. The rule is now a
## SHARED question every consumer asks, and the escaping shapes are refused at
## the schema boundary too, so they never reach a consumer at all.
##
## **The two questions are not the same question (W5).** The first shape of
## this guard asked ONE question at the schema boundary and refused `.` there
## too. That was wrong, and wrong in a way the system contradicted itself
## about: `.` is how a workspace declares its ROOT repo — the only repo that
## can carry the root's own `depends` edges, the repo that KEYS a
## commit-addressed lock backend, and the repo `repro develop` has a bespoke
## diagnostic for being asked to develop. Reprobuild SYNTHESIZES `path: "."`
## into the locks it writes and `readLock` accepts it, so a reader that
## refused it rejected a value its own writer emits. So there are two
## questions and each is asked where it belongs:
##
##   * `declaredCheckoutPathRejection` — the schema boundary. May this value
##     be DECLARED? `.` may (and only in that exact spelling, because every
##     consumer recognizes the root with a literal `== "."` compare).
##   * `checkoutPathRejection` — the own-tree question, asked immediately in
##     front of a `removeDir`. May a consumer CREATE or DELETE this directory
##     as the repo's own tree? `.` may not, ever.
##
## **There is a THIRD question, and it is not on the manifest plane at all
## (W5, second pass).** The paragraph this comment used to carry said that
## `repro develop`'s placement deletes were safe because "`developCheckoutDir`
## remaps `.` to a sibling before any path is computed". There is no
## `developCheckoutDir`. The proc is `developAllTargetPath`, its exemption is
## a literal `!= "."` compare, and the lock reader feeding it validated
## nothing about `path` at all — so a committed `repro.lock` carrying
## `path = "./."` produced a develop target equal to the workspace root, and
## `repro develop --all --reset` ran `removeDir` on it. Measured: a workspace
## holding `.git`, `PRECIOUS.txt`, `repro.lock` and `src/` was reduced to an
## empty directory, and the run then printed a REFUSAL from the (correctly
## guarded) half-clone cleanup two lines after the unguarded delete had
## already taken everything.
##
## So the lock plane has a boundary of its own, and it asks a DIFFERENT
## question again, because the develop plane's placements are not beneath the
## workspace root — its documented DEFAULT is the sibling topology one level
## above it (`../<name>`):
##
##   * `declaredCheckoutPathRejection` — the MANIFEST schema boundary. May
##     this value be DECLARED in a fragment? `.` may (and only in that exact
##     spelling); `..` may not, ever.
##   * `checkoutPathRejection` — the own-tree question, asked immediately in
##     front of a `removeDir` on the manifest plane. May a consumer CREATE or
##     DELETE this directory as the repo's own tree? `.` may not, ever.
##   * `lockedCheckoutPathRejection` — the LOCK boundary. May a lock record
##     this checkout path? `.` and `""` may (they are how a lock spells the
##     root repo, and the model excludes it by `isRootLockedDep`); `../sib`
##     may, because that is the documented sibling topology; every OTHER
##     spelling that resolves to the workspace root (`./.`, `./`, `a/..`) and
##     everything that resolves to an ANCESTOR of it (`..`, `../..`) may not.
##
## Asserted:
##   1. Reading a repo fragment whose `path` is `..`, a `..`-containing path,
##      a `.`-only path in any spelling OTHER than `.` itself, an absolute
##      path, or empty is REFUSED, and the diagnostic names the offending
##      fragment file and the key.
##   2. Ordinary paths — including nested ones like `a/b/c`, which real
##      manifests use for vendored reference trees — still resolve unchanged.
##      The guard must not be so eager that it breaks the layouts in use.
##   3. `path = "."` READS — and is still refused by the own-tree question, so
##      the exemption is a declaration exemption and nothing more. The three
##      questions are asserted side by side, including the one value they
##      disagree about (`../sib`: refused as a declaration, refused as an
##      own tree, ACCEPTED as a lock record).
##   4. Belt to that pair of braces: handed such a path DIRECTLY, past the
##      reader, the clone action's cleanup still refuses to delete the
##      workspace root or an ancestor of it.
##   5. The second delete site, end to end: `repro workspace disable` on a
##      project that declares the root repo at `.` refuses to remove it — even
##      under `--force`, which skips every other gate — while still removing
##      the ordinary checkout beside it. This is the case that stops the
##      declaration exemption from leaking into the delete, which is what
##      `1c005c6f` was closing.
##   6. The THIRD delete site, end to end: `repro remove`'s RA-22 reachability
##      GC. It reaches the root by two routes — NAMED as the target, and swept
##      into the GC set through another target's `depends` closure — and they
##      are answered differently on purpose (refuse the request vs. skip the
##      one delete). Both are asserted. This is the site the first shape of
##      W5 missed: its `removeDir` asked no question of its own, so the reader
##      guard was not redundant there, it was the only thing in the way.
##   7. The FOURTH delete site, end to end: `repro sync --force-sync`. It is
##      not a `removeDir` — it is `git clean -ffdx`, whose "bounded by the
##      repo's tree" is a bound only while that tree is the repo's own. On the
##      workspace root it deletes the manifests AND every sibling checkout.
##      The fix is NOT a refusal: `git reset --hard` is bounded by git's
##      TRACKED set and is in bounds on the root repo, so the reset runs, the
##      clean is skipped, and the row says PARTIALLY overwrote and why.
##   8. The FIFTH delete site, end to end, and the one on a plane that had no
##      boundary at all: `repro develop --all --reset` driven from a committed
##      `repro.lock`. Every spelling that collapses to the workspace root or
##      to an ancestor of it is refused AT THE LOCK READER, so no consumer
##      sees it; `../sib` still places a sibling, because that is the
##      documented default this boundary had to be written around.
##   9. The lock's OTHER delete-steering path segment: `coordinates.revision`,
##      which sits next to the already-guarded `name` in
##      `<producerCacheRoot> / name / revision` and reaches the same
##      `removeDir`. Refused at the same reader; a real revision still runs.
##  10. The lock's delete-steering string that is NOT a path — a fetch URL.
##      `urlSlug` turns it into a cache-relative directory that three clone
##      cleanups delete, and a `..` in the URL's path used to survive into
##      that directory verbatim. It is fixed where the URL BECOMES a path
##      rather than at the lock boundary, because `..` is legal in a remote
##      path and because the same slug is also reached from a MANIFEST
##      `repo.remote` that never passes a lock boundary at all. Unit level:
##      the slug's shape and the containment of the two computed paths.
##  11. ...and case 10's property driven END TO END, because a slug asserted
##      against a temp directory that is never used as a cache shows the rule
##      is applied and not that it prevents anything. A hostile URL goes into
##      the REAL `refreshSharedBare` and the REAL `ensureManifestCache` with a
##      real `git`, against a real victim directory on disk; the victim's own
##      existence is what fails the clone, which is what makes the whole
##      incident offline and deterministic. Measured on `d0c6ad8f`: victim
##      deleted, sentinel gone, in both arms. A decoy pre-created at the
##      computed path and asserted GONE afterwards is what stops this being a
##      case that passes because no delete ran.
##
##      TWO OF THE THREE cleanup paths, stated plainly rather than left to be
##      inferred from the arm list. Case 10 names three `removeDir` sites that
##      the slug steers; this case drives two of them. `git_actions.nim`'s
##      `refresh-bare` executor is NOT covered end to end — it reaches
##      `sharedBarePath` through the same `urlSlug`, so the rule that contains
##      it is the one asserted here, but no case in this file drives that
##      executor against a real victim. Reaching it needs an engine graph and
##      a resolved `GitToolIdentity`, which is a fixture this file does not
##      own; the gap is recorded rather than papered over.
##
## An eleventh consumer of the same boundary is asserted ELSEWHERE and is
## named here so this list is not read as the whole of it: the PUSH GATEWAY.
## `gatewayVerifyPublicLock` reads a pushed `repro.lock` through the same
## `parseWorkspaceLockedDeps` and refuses one that records an unusable
## checkout path — the last point at which such a lock is still one author's
## problem rather than every future cloner's. Its case lives with the gate's
## other two refusals, in
## `t_pre_receive_rejects_public_lock_with_private_ref_and_integrity_mismatch.nim`,
## because that file already owns the real bare-repo hook fixture and a
## second copy of it here would be a second thing to keep true.
##
##  12. **W8-R1/R2 — the same five consumers, asked of the RESOLVED target.**
##      Cases 1-11 all rest on LEXICAL path comparison, and a lexical rule is
##      blind to reparse points by construction. `path = "../sib"` is accepted
##      BY DESIGN — a sibling is a peer of the workspace and the develop
##      plane's documented default placement — so when `sib` is a directory
##      junction or symlink aimed at the workspace, the accepted value
##      resolves to the workspace root and no amount of string folding can
##      tell. Measured on `09324b61`: `repro develop --all --reset` reduced a
##      workspace holding `.git`, `PRECIOUS.txt`, `src\` and `repro.lock` to
##      `.repro` alone and EXITED 0 — an irreversible delete that reported
##      having done the right thing, which is worse than the `./.` case above
##      that at least exited 1. The same compares were byte-wise, so two
##      spellings of one directory differing only in case came out unequal on
##      a case-insensitive volume (latent, because every caller derived both
##      sides from the same bytes).
##
##      Both are now one decision — `repro_core/path_identity.nim`'s
##      `fsContainment`, which resolves each side through the filesystem
##      (`GetFinalPathNameByHandle` with `FILE_NAME_NORMALIZED` on Windows,
##      `realpath(3)` on POSIX) and confirms the two CATASTROPHIC verdicts
##      against `(volume, file id)` / `(st_dev, st_ino)` identity — applied at
##      all five deleting consumers. Five cases assert it: the primitive at
##      unit level, then `developPlacementRejection`,
##      `removeCloneTargetSafely` + `executeForceReset`,
##      `runWorkspaceDisableCommand` and `executeRemove` end to end. Every one
##      of them covers BOTH reparse tags (a junction is
##      `IO_REPARSE_TAG_MOUNT_POINT`, a directory symlink is
##      `IO_REPARSE_TAG_SYMLINK`, and Windows does not treat them alike), and
##      every one of them asserts its own PRE-STATE — that
##      `normalizedPath(absolutePath(...))` really does read the fixture as a
##      disjoint sibling — so no assertion can pass for a reason other than
##      resolution. The NEGATIVE direction is asserted just as hard: a genuine
##      `../sib` must still clone and still `--reset`, because refusing it is
##      the regression W5's third round shipped and had to repair.
##
## Product sites that irreversibly delete on a repo-derived path are FIVE, and
## each answers for itself: `git_actions.nim`'s `removeCloneTargetSafely`
## (case 4), `runWorkspaceDisableCommand` (case 5), `executeRemove` (case 6),
## `executeForceReset` (case 7), and `repro develop --all --reset`'s
## `removeDir` + `discardPartialCheckout` (case 8). The two in
## `git_actions.nim` share one containment proc rather than a private copy
## each. `executeForcePushRebase`'s `git reset --hard` and the post-clone
## reset in `repro sync` are bounded to git's TRACKED set and cannot reach an
## untracked sibling checkout, which is what makes `clean -ffdx` the outlier
## and what makes the case-7 narrowing sound.
##
## No mocks: real manifest files on disk read by the real reader, a real
## clone action executed through the real build engine against a real
## `git init --bare` origin, the engine-built `repro` binary for (5), (6),
## (7) and (8), and for (11) the real shared-clone procs driving a real `git`
## against a real directory that a real `removeDir` destroys without the rule
## in place.

import std/[os, osproc, strutils, tempfiles, unittest]
# `removeDirectoryW` only. See `removeDirReparsePoint` below: Nim's `removeDir`
# cannot delete a directory reparse point on Windows, and every W8 fixture in
# this file creates one.
when defined(windows):
  import std/winlean

import repro_build_engine
import repro_core/path_identity
import repro_workspace_manifests
import repro_test_support
import git_actions
import git_tool
import shared_clones

const ReprobuildRepoRoot =
  currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory. `currentSourcePath()` is
  ## absolute on both platforms (measured on the stock Windows 2.2.8 and on
  ## the `nix develop` fork 2.3.1, whose canonical *assertion* locations are a
  ## different mechanism and do not reach this one), so `reproBinary` below
  ## names the same file from every cwd.

const reproBinary =
  when defined(windows): ReprobuildRepoRoot / "build/bin/repro.exe"
  else: ReprobuildRepoRoot / "build/bin/repro"
  ## Spelled with the literal path IN THE SOURCE on both branches, and that
  ## spelling is load-bearing rather than stylistic.
  ##
  ## `scripts/generate_test_edges.nim`'s `detectReproBinaryUsage` decides
  ## `requiresReproBinary` in `repro_tests.nim`, which is what makes
  ## `repro.nim` record the engine-built CLI as a typed input on this test's
  ## EXECUTE edge. Without that input the edge declares no dependency on the
  ## CLI, so a change to `repro_cli_support.nim` does not invalidate this
  ## test's cache entry and `repro build test` reports a HIT on a stale
  ## result — a guard test that silently does not re-run is not a guard.
  ##
  ## The detector is a substring scan with three triggers, and it is worth
  ## being exact about which one fires, because the previous spelling here
  ## (`"./build/bin/" & addFileExt("repro", ExeExt)`) did NOT contain
  ## `build/bin/repro` — the concatenation splits it — and the flag was true
  ## only by accident, via the third trigger: the identifier `reproBinary`
  ## CONTAINS `reproBin`, and `runShell` appears below. Renaming this constant
  ## would have turned the flag silently false. Written out in full, the FIRST
  ## trigger fires on the literal itself and the flag no longer depends on
  ## what this identifier happens to be called. Anchoring the value on
  ## `ReprobuildRepoRoot` above keeps that property: the `build/bin/repro`
  ## literal is still present verbatim in both branches.

proc requireReproBinary(): string =
  ## The engine-built CLI, or a hard FAILURE.
  ##
  ## Deliberately not `skip()`. Four cases below drive the real binary, and a
  ## `skip()` when it is absent means this guard reports `[OK]` on a host that
  ## never ran it — which is how a campaign accumulates cases that have never
  ## executed. `requireBinary` raises `MissingTestFixtureError` naming the
  ## build-graph edge that produces the binary, and the `test` template's
  ## `except Exception` turns that into a reported failure from any call
  ## depth.
  requireBinary(absolutePath(reproBinary), "reprobuild.apps.repro")

proc q(value: string): string = quoteShell(value)

proc requireGit(gitBin, args: string): string =
  ## `doAssert`, not `check`/`fail`: this is a HELPER, outside any `test`
  ## body, where `unittest.fail` cannot see the `testStatusIMPL` the `test`
  ## template injects and degrades to `setProgramResult 1` — the case still
  ## reports `[OK]`. `doAssert` raises, and the `test` template's own
  ## `except Exception` reports it as a failure from any call depth.
  let res = execCmdEx(q(gitBin) & " " & args)
  doAssert res.exitCode == 0, "git " & args & " failed: exit=" &
    $res.exitCode & "\n" & res.output
  res.output

proc writeFragment(path, name, checkoutPath: string;
                   remote = "org"; depends: seq[string] = @[]) =
  var body =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"" & name & "\"\npath = \"" & checkoutPath & "\"\n" &
    "remote = \"" & remote & "\"\n"
  if depends.len > 0:
    var quoted: seq[string]
    for d in depends: quoted.add("\"" & d & "\"")
    body.add("depends = [" & quoted.join(", ") & "]\n")
  writeFile(path, body)

proc seedOrigin(gitBin, originPath, workPath: string) =
  ## Seed a bare origin from a fresh work tree. The committed body is derived
  ## from `workPath`, so two origins seeded in one test can never land on the
  ## same commit sha (a collision there produces a FALSE PASS, not a failure).
  discard requireGit(gitBin, "init --quiet --bare -b main " & q(originPath))
  discard requireGit(gitBin, "init --quiet -b main " & q(workPath))
  writeFile(workPath / "seed.txt", "seed " & extractFilename(workPath) & "\n")
  discard requireGit(gitBin, "-C " & q(workPath) & " add -A")
  discard requireGit(gitBin, "-C " & q(workPath) &
    " -c user.email=t@example.invalid -c user.name=t commit --quiet -m seed")
  discard requireGit(gitBin, "-C " & q(workPath) & " remote add origin " &
    q(originPath))
  discard requireGit(gitBin, "-C " & q(workPath) & " push --quiet origin main")

type ReparseKind = enum
  ## The two DIRECTORY reparse tags. They are not interchangeable and the
  ## distinction is why both are exercised below: a junction is
  ## `IO_REPARSE_TAG_MOUNT_POINT`, is created by a `cmd.exe` builtin, needs no
  ## privilege, and does not exist on POSIX at all; a directory symlink is
  ## `IO_REPARSE_TAG_SYMLINK`, needs Developer Mode or elevation on Windows,
  ## and is the ONLY one POSIX has. Windows treats them differently in enough
  ## places (`DeleteFile` semantics, remote-to-remote evaluation, `dir`
  ## reporting) that covering one and assuming the other is exactly the
  ## "fixed the site the reproduction happened to use" move W8 exists to
  ## avoid.
  rkJunction
  rkSymlink

proc reparseKindName(kind: ReparseKind): string =
  case kind
  of rkJunction: "junction"
  of rkSymlink: "symlink"

proc makeDirReparsePoint(kind: ReparseKind; linkPath, target: string):
    tuple[ok: bool; why: string] =
  ## Create a REAL directory reparse point at `linkPath` aimed at `target`.
  ##
  ## Non-raising on purpose, and it does NOT `skip()`: what an unavailable
  ## link kind means differs per platform and per host, so the CALLER decides
  ## and says so in a `checkpoint`. A junction is Windows-only; a Windows
  ## directory symlink needs Developer Mode or elevation.
  if kind == rkJunction:
    when defined(windows):
      # A real `mklink /J`. It is a `cmd.exe` BUILTIN, so it has to go through
      # `cmd.exe` — invoked with an argument ARRAY rather than a command
      # string, so nothing re-parses a quoted Windows path on the way (W6).
      let comspec = block:
        let fromEnv = getEnv("ComSpec")
        if fromEnv.len > 0: fromEnv
        else: getEnv("SystemRoot", r"C:\Windows") / "System32" / "cmd.exe"
      var output = ""
      try:
        output = execProcess(comspec,
          args = ["/c", "mklink", "/J", linkPath, target],
          options = {poStdErrToStdOut, poUsePath})
      except CatchableError as err:
        return (false, "mklink /J could not be run: " & err.msg)
      if not dirExists(linkPath):
        return (false, "mklink /J created nothing at " & linkPath & ": " &
          output.strip())
      return (true, "")
    else:
      return (false, "a directory junction is a Windows-only reparse tag")
  try:
    createSymlink(target, linkPath)
  except CatchableError as err:
    # Nim's `createSymlink` raises when `GetLastError()` is non-zero even on a
    # call that SUCCEEDED (`ossymlinks.nim`:52 ors the two conditions), so the
    # link on disk is the verdict here and the exception is not.
    if not (symlinkExists(linkPath) or dirExists(linkPath)):
      return (false, "createSymlink failed: " & err.msg)
  if not (symlinkExists(linkPath) or dirExists(linkPath)):
    return (false, "createSymlink produced nothing at " & linkPath)
  (true, "")

proc removeDirReparsePoint(path: string) =
  ## Delete the LINK. Never what it points at.
  ##
  ## This exists because of a tracked defect that is OUT OF SCOPE to fix here
  ## and would otherwise turn every case below red for a reason unrelated to
  ## what it asserts: `removeDir` (and `removeDirEventually`) cannot remove a
  ## directory reparse point on Windows — Nim reaches `DeleteFileW`, which
  ## answers `Access is denied`, when the call it needs is `RemoveDirectoryW`.
  ## Every fixture below creates a reparse point inside its scratch directory,
  ## so the scratch teardown would raise.
  ##
  ## `RemoveDirectoryW` on a reparse point removes the reparse point and
  ## leaves the target alone, which is also what makes it safe to call on a
  ## link that may point at the fixture's own workspace.
  if not (dirExists(path) or symlinkExists(path) or fileExists(path)):
    return
  when defined(windows):
    discard removeDirectoryW(newWideCString(path))
  else:
    removeFile(path)

proc lexicallyDisjoint(a, b: string): bool =
  ## What the OLD rule computed, kept so every case below can assert its own
  ## NON-VACUITY: the two paths must be unequal and neither a prefix of the
  ## other under `normalizedPath(absolutePath(...))`, which is precisely the
  ## comparison W5 shipped. If this is false the fixture is not testing
  ## resolution at all — the lexical rule would have caught it too.
  let na = os.normalizedPath(absolutePath(a))
  let nb = os.normalizedPath(absolutePath(b))
  na != nb and not na.startsWith(nb & $DirSep) and
    not nb.startsWith(na & $DirSep)

suite "a declared checkout path cannot escape the workspace root":

  test "t_degenerate_checkout_paths_are_refused_at_the_schema_boundary":
    let scratch = createTempDir("repro-pathguard-reject-", "")
    defer: removeDir(scratch)

    # Each of these turns `<workspaceRoot> / <path>` into something that is not
    # the repo's own tree — the workspace root itself, or a directory outside
    # it entirely.
    #
    # `.` is deliberately NOT in this list: it is the workspace ROOT repo's own
    # declaration and is asserted to READ in
    # `t_the_root_repo_declares_itself_at_dot_and_is_still_undeletable` below.
    # `./.` and `.//.` ARE here, and stay here: they denote the same directory
    # but are not the string `.`, and every consumer recognizes the root with a
    # literal `== "."` compare — so admitting them would produce a repo the
    # model reads as an ordinary sibling whose tree is the workspace root,
    # which is the confusion this whole guard exists to prevent.
    const degenerate = ["..", "../sibling", "a/../..", "./.", ".//.",
                        "nested/../../escape"]
    for idx, value in degenerate:
      let fragment = scratch / ("bad-" & $idx & ".toml")
      writeFragment(fragment, "bad-" & $idx, value)
      var refused = false
      try:
        discard readRepoFragment(fragment)
      except WorkspaceManifestParseError as err:
        refused = true
        # The diagnostic has to be actionable: which file, which key, and the
        # value that was rejected. "Invalid manifest" would send the reader
        # hunting through 163 fragments.
        check err.path == fragment
        check err.keyPath == "repo.path"
        check err.msg.contains(value)
      if not refused:
        checkpoint("checkout path '" & value & "' was accepted")
      check refused

    # An absolute path is refused too. Written separately because its spelling
    # differs per platform.
    let absolutePathValue =
      when defined(windows): "C:/somewhere/else"
      else: "/somewhere/else"
    let absFragment = scratch / "bad-abs.toml"
    writeFragment(absFragment, "bad-abs", absolutePathValue)
    var absRefused = false
    try:
      discard readRepoFragment(absFragment)
    except WorkspaceManifestParseError as err:
      absRefused = true
      check err.keyPath == "repo.path"
    check absRefused

    # ...and so is an empty one, which the pre-existing required-key check
    # already caught; asserted here so the two guards cannot both be removed
    # on the assumption that the other covers it.
    let emptyFragment = scratch / "bad-empty.toml"
    writeFragment(emptyFragment, "bad-empty", "")
    var emptyRefused = false
    try:
      discard readRepoFragment(emptyFragment)
    except WorkspaceManifestParseError as err:
      emptyRefused = true
      check err.keyPath == "repo.path"
    check emptyRefused

    # The manifest-repo SHA lock (`locks/<project>/<sha>.toml`) records the
    # SAME checkout paths and is asked the SAME question. It validated only
    # non-emptiness, so a value the fragment reader refuses round-tripped
    # through a lock untouched — and a lock is machine-written, which is the
    # population a degenerate value actually arrives from.
    let shaLock = scratch / "sha-lock.toml"
    writeFile(shaLock,
      "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
      "[lock]\nproject = \"demo\"\ncreated_at = \"2026-01-01T00:00:00Z\"\n\n" &
      "[[repo]]\nname = \"ws-root\"\npath = \"./.\"\n" &
      "remote = \"org\"\nrevision = \"main\"\n")
    var shaLockRefused = false
    try:
      discard readLock(shaLock)
    except WorkspaceManifestParseError as err:
      shaLockRefused = true
      check err.keyPath == "repo[0].path"
      check err.msg.contains("./.")
      # RA-28 even here: a lock is regenerated, not hand-edited.
      check err.msg.contains("repro workspace lock")
    if not shaLockRefused:
      checkpoint("readLock accepted repo[].path = './.'")
    check shaLockRefused

    # ...and the value its own writer emits still READS. A reader that
    # refuses what the writer produces is the defect this whole milestone
    # started from.
    let rootShaLock = scratch / "sha-lock-root.toml"
    writeFile(rootShaLock,
      "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
      "[lock]\nproject = \"demo\"\ncreated_at = \"2026-01-01T00:00:00Z\"\n\n" &
      "[[repo]]\nname = \"ws-root\"\npath = \".\"\n" &
      "remote = \"org\"\nrevision = \"main\"\n")
    let readRootLock = readLock(rootShaLock)
    check readRootLock.repo.len == 1
    check readRootLock.repo[0].path == "."

  test "t_ordinary_and_nested_checkout_paths_still_resolve":
    let scratch = createTempDir("repro-pathguard-accept-", "")
    defer: removeDir(scratch)

    # Nested paths are not exotic: real manifests check vendored reference
    # trees out underneath another repo's directory. A guard that rejected them
    # would be worse than the hazard it closes.
    const fine = ["lib-a", "reprobuild/references/buildxl",
                  "references-gpl/seL4", "a/b/c/d"]
    for idx, value in fine:
      let fragment = scratch / ("ok-" & $idx & ".toml")
      writeFragment(fragment, "ok-" & $idx, value)
      let read = readRepoFragment(fragment)
      check read.repo.path == value

  test "t_the_root_repo_declares_itself_at_dot_and_is_still_undeletable":
    ## W5 — the exemption, and its exact width.
    ##
    ## `.` is the workspace ROOT repo declaring itself. The model already
    ## carries it everywhere else: `readLock` accepts `path = "."` in a
    ## `reprobuild.workspace.lock.v1` record, reprobuild WRITES that value into
    ## the locks it emits, and `isRootLockedDep` / the root lookup in
    ## `composeDevelopLockSet` both recognize it. The reader refusing what the
    ## writer emits was the defect; this is the assertion that it does not
    ## come back.
    ##
    ## The second half is the half that matters more. The exemption is for the
    ## DECLARATION only — `checkoutPathRejection`, the question every delete
    ## site asks, still refuses `.`, so relaxing the schema boundary did not
    ## relax the `removeDir`s that `1c005c6f` was written for.
    let scratch = createTempDir("repro-pathguard-root-", "")
    defer: removeDir(scratch)

    let rootFragment = scratch / "ws-root.toml"
    writeFragment(rootFragment, "ws-root", ".")
    let read = readRepoFragment(rootFragment)
    check read.repo.name == "ws-root"
    check read.repo.path == "."

    # The THREE questions, side by side, so a future edit cannot collapse any
    # two of them into one without this case saying so.
    check declaredCheckoutPathRejection(".") == ""
    check checkoutPathRejection(".").len > 0
    check checkoutPathRejection(".").contains("workspace root itself")
    # A lock spells the root repo `.` (what reprobuild writes) or `""` (a lock
    # that omits the key), and `isRootLockedDep` matches both — so both pass
    # the lock boundary and are excluded from the develop set by the MODEL
    # rather than by a guard.
    check lockedCheckoutPathRejection(".") == ""
    check lockedCheckoutPathRejection("") == ""

    # The one value the three questions DISAGREE about, and the reason the
    # lock boundary could not simply reuse the manifest one: `../sib` is an
    # escape in a manifest and the documented DEFAULT placement of a develop
    # checkout (CLI/develop.md §"Checkout Placement").
    check declaredCheckoutPathRejection("../sib").len > 0
    check checkoutPathRejection("../sib").len > 0
    check lockedCheckoutPathRejection("../sib") == ""

    # Every OTHER degenerate value answers all three identically. On the lock
    # plane they split into the two shapes that are catastrophic there:
    # collapsing to the workspace root, and collapsing to an ancestor of it.
    for value in ["./.", ".//.", "a/.."]:
      check declaredCheckoutPathRejection(value).len > 0
      check checkoutPathRejection(value).len > 0
      check lockedCheckoutPathRejection(value).contains("the workspace root")
    for value in ["..", "../..", "a/../..", "../sib/.."]:
      check declaredCheckoutPathRejection(value).len > 0
      check checkoutPathRejection(value).len > 0
      check lockedCheckoutPathRejection(value).contains(
        "CONTAINS the workspace root")
    check declaredCheckoutPathRejection("").len > 0
    check checkoutPathRejection("").len > 0

    # Every rejection the lock boundary produces carries a copy-pasteable
    # remedy, because a lock is machine-written and "fix it by hand" is not
    # an instruction (RA-28 / Interactive-UX-And-Progress.md Principle 2).
    for value in ["./.", "..", "a/.."]:
      check lockedCheckoutPathRejection(value).contains("repro lock refresh")

    for value in ["lib-a", "a/b/c/d", "reprobuild/references/buildxl"]:
      check declaredCheckoutPathRejection(value) == ""
      check checkoutPathRejection(value) == ""
      check lockedCheckoutPathRejection(value) == ""

    # A lock-supplied dependency NAME reaches `removeDir` too — the lock-
    # pinned producer cache is `<cacheRoot> / <name> / <revision>` — so it is
    # asked the traversal question. Only traversal: a name is not a checkout
    # path, so `.` and "" are not meaningful there and are not refused.
    check pathTraversalRejection("nim").len == 0
    check pathTraversalRejection("scoped/name").len == 0
    check pathTraversalRejection("../escape").len > 0
    check pathTraversalRejection("a/../../b").len > 0

  test "t_clone_cleanup_refuses_to_delete_the_workspace_root_or_an_ancestor":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pathguard-clone-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
      installGitVcsExecutor()

      # A real origin, so the only thing under test is where the cleanup
      # points — not whether the clone could have worked.
      let origin = scratch / "origin.git"
      let seed = scratch / "seed"
      discard requireGit(gitBin, "init --quiet --initial-branch main " & q(seed))
      writeFile(seed / "README.md", "seed\n")
      discard requireGit(gitBin, "-C " & q(seed) & " add .")
      discard requireGit(gitBin, "-C " & q(seed) &
        " -c user.email=t@example.invalid -c user.name=t commit --quiet -m seed")
      discard requireGit(gitBin, "clone --quiet --bare " & q(seed) & " " &
        q(origin))

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      # Contents that must survive. The workspace root is deliberately NOT a
      # git checkout: that is what sends `executeClone` down its half-clone
      # cleanup branch, which is the branch that used to hold the unbounded
      # `removeDir`.
      writeFile(workspaceRoot / "precious.txt", "must survive\n")
      createDir(workspaceRoot / "precious-dir")
      writeFile(workspaceRoot / "precious-dir" / "inner.txt", "also\n")

      # `path = "."` — past the reader, which can no longer produce it. This is
      # the shape a synthesized action or a resolver defect hands over.
      var action = gitCloneAction("escape-clone", identity,
        remoteUrl = "file://" & origin.replace('\\', '/'),
        repoPath = ".",
        receiptPath = ".repro" / "escape.receipt",
        revision = "main")
      action.cwd = workspaceRoot
      var config = defaultBuildEngineConfig(scratch / "engine-cache")
      config.suppressTrace = true
      config.fallbackToRunQuotaBypass = true
      let res = runBuild(graph([action]), config)

      # The action FAILS — refusing to delete is the correct outcome, and a
      # refusal that reported success would be worse than the delete.
      check res.results.len == 1
      check res.results[0].status notin {asSucceeded, asCacheHit, asUpToDate}

      # ...and everything that was in the workspace root is still there.
      check dirExists(workspaceRoot)
      check fileExists(workspaceRoot / "precious.txt")
      check readFile(workspaceRoot / "precious.txt") == "must survive\n"
      check fileExists(workspaceRoot / "precious-dir" / "inner.txt")

      # RA-28's second half. The refusal used to say "fix the declared
      # checkout path for this repo" and name no file at all, which is a work
      # item rather than a remedy. This executor is handed a directory and a
      # workspace root and nothing else, so it cannot name the one offending
      # fragment — but it can name the two files a checkout path is declared
      # in and the key in each, plus the command that maps repo to path.
      let diag = res.results[0].reason & "\n" & res.results[0].stderr
      checkpoint("clone cleanup refusal: " & diag)
      check diag.contains("repo.path")
      check diag.contains("deps[].path")
      check diag.contains(workspaceRoot / "repro.lock")
      check diag.contains("repro workspace repos list")

      # An ANCESTOR of the workspace root is refused the same way, and its
      # contents are untouched. `..` from the workspace root is `scratch`,
      # which HOLDS the workspace.
      #
      # A merely DISJOINT sibling (`../sibling`) is deliberately NOT asserted
      # here, and that is a change from the first shape of this guard.
      # `executeClone` serves two planes: the manifest plane, where `..` is
      # refused at the reader and so no sibling payload can reach this
      # executor at all, and the DEVELOP plane, whose documented default
      # placement IS a sibling (`../<name>`). Refusing siblings in the
      # executor broke the second one outright — measured, a
      # `repro develop --all` of a node locked at `path = "../sib"` failed
      # with `force-reset-target-not-contained` and left the checkout at the
      # branch tip. So the executor asks only what is catastrophic on BOTH
      # planes, and the plane-specific rule is enforced where the plane is
      # known: the manifest reader (case 1) and the lock boundary (case 8).
      writeFile(scratch / "ancestor-witness.txt", "leave me\n")
      var escape = gitCloneAction("escape-clone-2", identity,
        remoteUrl = "file://" & origin.replace('\\', '/'),
        repoPath = "..",
        receiptPath = ".repro" / "escape2.receipt",
        revision = "main")
      escape.cwd = workspaceRoot
      let res2 = runBuild(graph([escape]), config)
      check res2.results.len == 1
      check res2.results[0].status notin {asSucceeded, asCacheHit, asUpToDate}
      check fileExists(scratch / "ancestor-witness.txt")
      check readFile(scratch / "ancestor-witness.txt") == "leave me\n"
      check dirExists(workspaceRoot)
      check fileExists(workspaceRoot / "precious.txt")

  test "t_workspace_disable_still_refuses_to_remove_the_workspace_root":
    ## W5 — the OTHER delete site, end to end, through the real CLI.
    ##
    ## Before the declaration exemption this case was unreachable: a project
    ## declaring its root repo at `.` could not be read at all, so
    ## `workspace disable` never got as far as computing
    ## `<workspaceRoot> / "."`. The exemption makes it reachable, which is
    ## exactly why it must be pinned here: the whole point of `1c005c6f` was
    ## that the recovery paths — the ones nobody exercises by hand — turn a
    ## degenerate declaration into an unbounded recursive delete.
    ##
    ## `--force` is deliberate. It skips the work-loss gate, which is the
    ## other thing that could stop this delete, so what survives is attributed
    ## to the own-tree guard and nothing else. The ordinary checkout beside it
    ## IS removed in the same run, so the refusal is proven targeted rather
    ## than the command simply failing early.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let repro = requireReproBinary()
      let scratch = createTempDir("repro-pathguard-disable-", "")
      defer: removeDir(scratch)

      # Two origins, each seeded with its OWN body: `seedOrigin` derives the
      # committed content from the work path, so the two cannot land on the
      # same commit sha. An identical sha here would be a false PASS, not a
      # failure.
      let onlyMineOrigin = scratch / "origin-only-mine.git"
      let keeperOrigin = scratch / "origin-keeper.git"
      seedOrigin(gitBin, onlyMineOrigin, scratch / "seed-only-mine")
      seedOrigin(gitBin, keeperOrigin, scratch / "seed-keeper")
      check requireGit(gitBin, "-C " & q(scratch / "seed-only-mine") &
          " rev-parse HEAD").strip() !=
        requireGit(gitBin, "-C " & q(scratch / "seed-keeper") &
          " rev-parse HEAD").strip()

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      # What a delete of `<workspaceRoot> / "."` would destroy.
      writeFile(workspaceRoot / "precious.txt", "must survive\n")
      createDir(workspaceRoot / "precious-dir")
      writeFile(workspaceRoot / "precious-dir" / "inner.txt", "also\n")

      writeFragment(workspaceRoot / "repos" / "ws-root.toml", "ws-root", ".")
      writeFragment(workspaceRoot / "repos" / "only-mine.toml",
        "only-mine", "only-mine")
      writeFragment(workspaceRoot / "repos" / "keeper.toml",
        "keeper", "keeper")

      let remotes =
        "[[remote]]\nname = \"org\"\nfetch = \"" &
          fileUrl(onlyMineOrigin) & "\"\n\n" &
        "[[remote]]\nname = \"keeper-origin\"\nfetch = \"" &
          fileUrl(keeperOrigin) & "\"\n\n"
      writeFile(workspaceRoot / "projects" / "rooted.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"rooted\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" & remotes &
        "includes = [\n  \"repos/ws-root.toml\",\n" &
        "  \"repos/only-mine.toml\",\n]\n")
      # A second project stays enabled. `disable` refuses to record an EMPTY
      # active set, so a one-project workspace would fail before the removal
      # loop is reached at all — and the removal loop is what is under test.
      writeFile(workspaceRoot / "projects" / "keeper.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"keeper\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" & remotes &
        "includes = [\n  \"repos/keeper.toml\",\n]\n")

      writeWorkspaceProjects(workspaceRoot, @["rooted", "keeper"])
      discard requireGit(gitBin, "clone --quiet " &
        q(fileUrl(onlyMineOrigin)) & " " & q(workspaceRoot / "only-mine"))
      discard requireGit(gitBin, "clone --quiet " & q(fileUrl(keeperOrigin)) &
        " " & q(workspaceRoot / "keeper"))
      check dirExists(workspaceRoot / "only-mine" / ".git")

      let res = runShell(shellCommand([repro, "workspace", "disable",
        "rooted", "--force", "--workspace-root=" & workspaceRoot]))

      # One removal was refused, so the verb reports failure (exit 1) rather
      # than claiming a clean disable.
      if res.code != 1:
        checkpoint("workspace disable output: " & res.output)
      check res.code == 1
      check res.output.contains(
        "refusing to remove the declared checkout path '.'")
      check res.output.contains("not the workspace root itself")
      # RA-28 (Interactive-UX-And-Progress.md Principle 2): the refusal names
      # the offender — the resolved directory, not just the string `.` — and
      # a copy-pasteable command. Without the second half the operator is
      # told a removal was refused and given nowhere to go.
      check res.output.contains("IS the workspace root")
      check res.output.contains("git -C ")
      check res.output.contains("left in place")

      # The ordinary checkout the same command was asked to remove is gone,
      # so the refusal was aimed at `.` and not at the whole run. Asserted
      # FIRST because it is the most specific claim here: everything below is
      # also true of a command that simply failed early and did nothing.
      check not dirExists(workspaceRoot / "only-mine")
      # The still-enabled project's checkout is untouched, as always.
      check dirExists(workspaceRoot / "keeper" / ".git")

      # ...and the workspace root and everything in it survived.
      check dirExists(workspaceRoot)
      check dirExists(workspaceRoot / "projects")
      check dirExists(workspaceRoot / "repos")
      check fileExists(workspaceRoot / "precious-dir" / "inner.txt")
      check fileExists(workspaceRoot / "precious.txt")
      # Guarded: a bare `readFile` on the file the defect deletes RAISES, and
      # a raise out of a `check` argument ends the case at this line — so the
      # assertions that name what actually went missing would never run. The
      # `fileExists` above is what fails when the defect fires; this one only
      # adds "and the content is right".
      if fileExists(workspaceRoot / "precious.txt"):
        check readFile(workspaceRoot / "precious.txt") == "must survive\n"

  test "t_repro_remove_refuses_the_workspace_root_by_name_and_in_the_gc_set":
    ## W5 — the THIRD delete site on a repo-derived path, end to end.
    ##
    ## `repro remove`'s RA-22 reachability GC ends in a bare
    ## `removeDir(<workspaceRoot> / p.repo.path)`. Before the declaration
    ## exemption it was unreachable for `.` only because `readRepoFragment`
    ## refused the value — this loop never asked the own-tree question itself.
    ## So the reader guard was not redundant here, it was the ONLY thing in
    ## the way, and lifting it made `repro remove` delete the workspace root
    ## and report exit 0. This case is the reason the guard now stands in
    ## front of this `removeDir` too.
    ##
    ## The root reaches the command by two routes and they are asserted
    ## separately, because they are answered differently on purpose:
    ##
    ##   * NAMED (`repro remove ws-root`) — the whole verb refuses and
    ##     NOTHING is mutated, not even the target's `includes` edge. A GC
    ##     that quietly skipped the delete would still drop the declaration
    ##     and still print a removal line, telling the operator a repo was
    ##     removed while its tree stayed.
    ##   * SWEPT IN — `only-mine` declares `depends = ["ws-root"]`, so the
    ##     root lands in the GC candidate set without anyone naming it, and
    ##     is unreachable from the one surviving root (`keeper`). Here only
    ##     the root's own delete is skipped: `only-mine` IS removed in the
    ##     same run, which is what proves the refusal is targeted rather than
    ##     the command merely failing early.
    ##
    ## `--force` throughout, and `only-mine` is left DIRTY on purpose: that
    ## makes the RA-9 work-loss gate fire, and `--force` walks straight
    ## through it. Every other thing that could stop this delete is therefore
    ## switched off, so what survives is attributable to the own-tree guard
    ## and to nothing else.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let repro = requireReproBinary()
      let scratch = createTempDir("repro-pathguard-remove-", "")
      defer: removeDir(scratch)

      # Distinct bodies per origin — `seedOrigin` derives the committed
      # content from the work path. Two constant-bodied fixtures seeded in
      # the same second land on the SAME commit sha, and a collision there
      # is a false PASS rather than a failure.
      let onlyMineOrigin = scratch / "origin-only-mine.git"
      let keeperOrigin = scratch / "origin-keeper.git"
      seedOrigin(gitBin, onlyMineOrigin, scratch / "seed-only-mine")
      seedOrigin(gitBin, keeperOrigin, scratch / "seed-keeper")
      check requireGit(gitBin, "-C " & q(scratch / "seed-only-mine") &
          " rev-parse HEAD").strip() !=
        requireGit(gitBin, "-C " & q(scratch / "seed-keeper") &
          " rev-parse HEAD").strip()

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      createDir(workspaceRoot / ".repro")
      # Exactly what a `removeDir(<workspaceRoot> / ".")` destroys — and did
      # destroy, reported as success, before this guard was added.
      writeFile(workspaceRoot / "precious.txt", "must survive\n")
      createDir(workspaceRoot / "precious-dir")
      writeFile(workspaceRoot / "precious-dir" / "inner.txt", "also\n")

      writeFragment(workspaceRoot / "repos" / "ws-root.toml", "ws-root", ".")
      writeFragment(workspaceRoot / "repos" / "only-mine.toml",
        "only-mine", "only-mine", depends = @["ws-root"])
      writeFragment(workspaceRoot / "repos" / "keeper.toml",
        "keeper", "keeper", remote = "keeper-origin")

      writeFile(workspaceRoot / "projects" / "rooted.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"rooted\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"org\"\nfetch = \"" &
          fileUrl(onlyMineOrigin) & "\"\n\n" &
        "[[remote]]\nname = \"keeper-origin\"\nfetch = \"" &
          fileUrl(keeperOrigin) & "\"\n\n" &
        "includes = [\n  \"repos/ws-root.toml\",\n" &
        "  \"repos/only-mine.toml\",\n  \"repos/keeper.toml\",\n]\n")
      writeFile(workspaceRoot / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"rooted\"\nbranch = \"main\"\n")

      discard requireGit(gitBin, "clone --quiet " &
        q(fileUrl(onlyMineOrigin)) & " " & q(workspaceRoot / "only-mine"))
      discard requireGit(gitBin, "clone --quiet " & q(fileUrl(keeperOrigin)) &
        " " & q(workspaceRoot / "keeper"))
      # Uncommitted work, so the RA-9 gate has something to fire on and
      # `--force` is doing real work rather than decorating the command line.
      writeFile(workspaceRoot / "only-mine" / "uncommitted.txt",
        "local work\n")

      let projectFile = workspaceRoot / "projects" / "rooted.toml"
      let projectBefore = readFile(projectFile)

      # ---- route 1: NAMED as the target -----------------------------------
      let named = runShell(shellCommand([repro, "remove", "ws-root",
        "--force", "--workspace-root=" & workspaceRoot]))
      if named.code == 0:
        checkpoint("repro remove ws-root output: " & named.output)
      check named.code == 1
      # RA-28: the offender is the REPO, not the string `.` — `ws-root` is
      # what the operator typed and what they have to act on — and the
      # remedy is the one that actually exists: the declaration can be
      # dropped without the delete.
      check named.output.contains("refusing to remove 'ws-root'")
      check named.output.contains("not the workspace root itself")
      check named.output.contains("IS the workspace root")
      check named.output.contains("Remedy:")
      # ...and the remedy is a COMMAND, not an instruction to hand-edit a
      # TOML array. This fixture is the FLAT membership layout, which
      # `repro workspace repos remove` can reach; the `.repro/manifests`
      # layout it cannot reach falls back to naming the file, the key and the
      # entry, which is asserted in
      # `t_gate_refusals_name_offender_and_remedy_command`. That case also
      # RUNS the command and asserts the declaration went and the tree
      # stayed — the only assertion that separates a remedy from a sentence.
      check named.output.contains("repro workspace repos remove ws-root")
      check named.output.contains("leaves the checkout on disk")
      check named.output.contains("repro sync")

      # Nothing at all was mutated: not the project file, not the other
      # checkouts, not the root. The project file first — it is the one this
      # route promises to leave alone and the one the SWEPT route below
      # legitimately changes, so it is what distinguishes them.
      check readFile(projectFile) == projectBefore
      check dirExists(workspaceRoot / "only-mine" / ".git")
      check dirExists(workspaceRoot / "keeper" / ".git")
      check dirExists(workspaceRoot)
      check dirExists(workspaceRoot / "projects")
      check dirExists(workspaceRoot / "repos")
      check fileExists(workspaceRoot / "precious-dir" / "inner.txt")
      check fileExists(workspaceRoot / "precious.txt")
      if fileExists(workspaceRoot / "precious.txt"):
        check readFile(workspaceRoot / "precious.txt") == "must survive\n"

      # ---- route 2: SWEPT INTO the GC set via `depends` --------------------
      let swept = runShell(shellCommand([repro, "remove", "only-mine",
        "--force", "--workspace-root=" & workspaceRoot]))
      if swept.code != 1:
        checkpoint("repro remove only-mine output: " & swept.output)
      check swept.code == 1
      check swept.output.contains("refusing to remove 'ws-root'")
      check swept.output.contains("not the workspace root itself")
      check swept.output.contains("Remedy:")
      check swept.output.contains("repro sync")

      # The ordinary checkout in the SAME GC set is gone — dirty, and removed
      # anyway under `--force`. Asserted FIRST: without it the run could have
      # "survived the root" by doing nothing at all, and every other
      # assertion below would still pass.
      check not dirExists(workspaceRoot / "only-mine")
      # A repo outside the GC set is untouched, as always.
      check dirExists(workspaceRoot / "keeper" / ".git")

      # ...and the workspace root and everything in it survived.
      check dirExists(workspaceRoot)
      check dirExists(workspaceRoot / "projects")
      check dirExists(workspaceRoot / "repos")
      check fileExists(workspaceRoot / "precious-dir" / "inner.txt")
      check fileExists(workspaceRoot / "precious.txt")
      if fileExists(workspaceRoot / "precious.txt"):
        check readFile(workspaceRoot / "precious.txt") == "must survive\n"

  test "t_force_sync_on_the_workspace_root_skips_the_clean_and_says_so":
    ## W5 — the FOURTH delete site, and the one the shape audit had to find
    ## because it is not a `removeDir` at all.
    ##
    ## `repro sync --force-sync` schedules `executeForceReset`, whose contract
    ## is that the tree ends byte-identical to a fresh checkout at the locked
    ## revision: `git reset --hard <sha>` plus `git clean -ffdx`. The second
    ## half is a recursive delete, bounded by the repo's tree — which is a
    ## bound only while that tree is the repo's OWN. Given `repoPath = "."`
    ## the target is the WORKSPACE ROOT, and from the root repo's point of
    ## view `projects/`, `repos/`, `.repro/` and EVERY SIBLING CHECKOUT are
    ## just untracked directories. `clean -ffdx` removes all of them.
    ##
    ## This was measured before it was guarded: the same fixture, run against
    ## the unguarded executor, lost `PRECIOUS-UNTRACKED.txt`, `projects/`,
    ## `repos/` and the whole `lib` checkout — a second repo's working tree,
    ## deleted by a "force-sync" of a different repo — and the command exited
    ## 0. That is the same class of harm as `repro remove`'s root delete
    ## arriving through a different verb, which is why the containment proof
    ## now lives in the executor rather than in any one caller.
    ##
    ## `lib` is the assertion that matters most: it is not the root, not the
    ## force-reset target, and not something `--force-sync` was ever asked to
    ## touch. If it survives, the delete was contained.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let repro = requireReproBinary()
      let scratch = createTempDir("repro-pathguard-forcesync-", "")
      defer: removeDir(scratch)

      let rootOrigin = scratch / "origin-root.git"
      let libOrigin = scratch / "origin-lib.git"
      seedOrigin(gitBin, rootOrigin, scratch / "seed-root")
      seedOrigin(gitBin, libOrigin, scratch / "seed-lib")
      check requireGit(gitBin, "-C " & q(scratch / "seed-root") &
          " rev-parse HEAD").strip() !=
        requireGit(gitBin, "-C " & q(scratch / "seed-lib") &
          " rev-parse HEAD").strip()

      # The workspace root IS a checkout of the root repo — that is what makes
      # `<workspaceRoot> / "."` a git working tree and so a legal force-reset
      # target as far as every check except the containment proof is
      # concerned.
      let workspaceRoot = scratch / "workspace"
      discard requireGit(gitBin, "clone --quiet " & q(fileUrl(rootOrigin)) &
        " " & q(workspaceRoot))
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      createDir(workspaceRoot / ".repro")

      writeFragment(workspaceRoot / "repos" / "ws-root.toml", "ws-root", ".",
        remote = "root-origin")
      writeFragment(workspaceRoot / "repos" / "lib.toml", "lib", "lib",
        remote = "lib-origin")
      writeFile(workspaceRoot / "projects" / "demo.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"demo\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"root-origin\"\nfetch = \"" &
          fileUrl(rootOrigin) & "\"\n\n" &
        "[[remote]]\nname = \"lib-origin\"\nfetch = \"" &
          fileUrl(libOrigin) & "\"\n\n" &
        "includes = [\n  \"repos/ws-root.toml\",\n  \"repos/lib.toml\",\n]\n")
      writeFile(workspaceRoot / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\nbranch = \"main\"\n")

      discard requireGit(gitBin, "clone --quiet " & q(fileUrl(libOrigin)) &
        " " & q(workspaceRoot / "lib"))

      # DIRTY the root repo, so the planner classifies it `dirty` and
      # `--force-sync` selects it for the overwrite. Both a tracked edit and
      # an untracked file: `reset --hard` would revert the first, `clean
      # -ffdx` would delete the second, and only the second is out of bounds.
      writeFile(workspaceRoot / "seed.txt", "local edit\n")
      writeFile(workspaceRoot / "PRECIOUS-UNTRACKED.txt", "must survive\n")

      let res = runShell(shellCommand([repro, "sync", "--force-sync",
        "--force", "--workspace-root=" & workspaceRoot]))
      checkpoint("force-sync output: " & res.output)

      # The narrowing, reported. The two halves of a force-reset are not
      # equally dangerous and only one of them is out of bounds on the root
      # repo: `git reset --hard` is bounded by git's TRACKED set, which on
      # the workspace root is the root repo's own files and nothing else, so
      # it RUNS; `git clean -ffdx` is bounded by the DIRECTORY, which on the
      # root repo is the whole workspace, so it is SKIPPED. The row says
      # PARTIALLY overwrote — over-claiming here would leave an operator
      # believing the tree is byte-identical to a fresh checkout while
      # untracked files survive — and carries the remedy for someone who does
      # want them gone.
      check res.output.contains("force-sync PARTIALLY overwrote '.'")
      check res.output.contains("did NOT run `git clean -ffdx`")
      check res.output.contains("clean -ndx")

      # The one that proves containment rather than luck, and asserted FIRST
      # because it is the most specific: a DIFFERENT repo's entire working
      # tree, which the unguarded executor deleted. It is not the root, not
      # the force-reset target, and not something `--force-sync` was ever
      # asked to touch.
      check dirExists(workspaceRoot / "lib" / ".git")
      check fileExists(workspaceRoot / "lib" / "seed.txt")

      # Everything else `git clean -ffdx` in the workspace root would have
      # taken.
      check dirExists(workspaceRoot)
      check dirExists(workspaceRoot / "projects")
      check dirExists(workspaceRoot / "repos")
      check fileExists(workspaceRoot / "projects" / "demo.toml")
      check fileExists(workspaceRoot / "repos" / "ws-root.toml")
      check fileExists(workspaceRoot / "PRECIOUS-UNTRACKED.txt")
      if fileExists(workspaceRoot / "PRECIOUS-UNTRACKED.txt"):
        check readFile(workspaceRoot / "PRECIOUS-UNTRACKED.txt") ==
          "must survive\n"

      # The half that DID run: the tracked edit is reverted. Without this the
      # case would pass against an executor that refused outright, which is
      # what the first shape of this fix did — and a permanent refusal with
      # no way out is not a fix, it is a dead end with a diagnostic.
      check fileExists(workspaceRoot / "seed.txt")
      if fileExists(workspaceRoot / "seed.txt"):
        check readFile(workspaceRoot / "seed.txt") != "local edit\n"

  test "t_develop_all_reset_refuses_a_lock_path_that_names_the_workspace":
    ## W5 (second pass) — the FIFTH delete site, on the plane that had no
    ## boundary at all.
    ##
    ## The manifest plane got a schema boundary and four delete sites that
    ## each ask for themselves. The LOCK plane got neither, and both feed the
    ## same deletes. `parseLockedDependencies` validates nothing about `path`;
    ## `isRootLockedDep` recognizes the root by a literal `path == "."` (or
    ## empty) compare, so `./.` is not read as the root and enters the develop
    ## set as an ordinary dependency; `developAllTargetPath` exempts the same
    ## literal, so it computes `<workspaceRoot> / "./."` — the workspace root;
    ## and `repro develop --all --reset` runs `removeDir` on it.
    ##
    ## Measured before it was guarded, and the shape of the harm is worse than
    ## `repro remove`'s in two ways: it takes `.git` (unrecoverable), and the
    ## run then printed a REFUSAL from the half-clone cleanup — which IS
    ## guarded — two lines after the unguarded delete had already taken
    ## everything, so the operator was told the command declined to touch the
    ## workspace while the workspace was gone.
    ##
    ## The fix is at the READER, not at the two `removeDir`s: every lock byte
    ## in the product becomes a `LockedDep` through one funnel, so a path
    ## refused there reaches no consumer — not this delete, not the next one
    ## someone adds. The delete sites keep a placement proof of their own as a
    ## belt, for targets that never came from a lock (`--into` is
    ## operator-supplied).
    ##
    ## `../sib` is the constraint the boundary was written around, not an
    ## exception carved out of it: the sibling topology one level above the
    ## workspace root is `repro develop`'s DOCUMENTED DEFAULT placement, so a
    ## rule that refused it would break the verb. It is asserted last, and it
    ## is the assertion that stops this guard from being fixed by refusing
    ## everything.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let repro = requireReproBinary()
      let scratch = createTempDir("repro-pathguard-lockplane-", "")
      defer: removeDir(scratch)

      let depOrigin = scratch / "origin-dep.git"
      seedOrigin(gitBin, depOrigin, scratch / "seed-dep")
      let depSha = requireGit(gitBin,
        "-C " & q(scratch / "seed-dep") & " rev-parse HEAD").strip()
      check depSha.len == 40

      # A committed-lock-only workspace: no `.repro/manifests` checkout and no
      # compositional `workspace.toml`, so `resolveWorkspaceLockedDeps` routes
      # it to the committed-lock source — the exact route the defect took.
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "src")
      discard requireGit(gitBin, "init --quiet -b main " & q(workspaceRoot))
      writeFile(workspaceRoot / "PRECIOUS.txt", "must survive\n")
      writeFile(workspaceRoot / "src" / "code.txt", "source\n")

      proc writeLock(checkoutPath: string) =
        writeFile(workspaceRoot / "repro.lock",
          "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
          "[lock]\nplatform = \"amd64-linux\"\noptimal = false\n" &
          "inputs_digest = \"fnv1a64:0000000000000000\"\n" &
          "variants = []\npackages = []\n" &
          "deps = [{ name = \"dep\", path = \"" & checkoutPath & "\", " &
          "coord_kind = \"vcs\", url = \"" & fileUrl(depOrigin) & "\", " &
          "ref = \"main\", revision = \"" & depSha & "\", " &
          "integrity = \"git-sha1:" & depSha & "\", version = \"\", " &
          "visibility = \"public\", participation = \"\", " &
          "depends = \"\", groups = \"\" }]\n")

      # Every spelling that collapses onto the workspace root, and every
      # spelling that collapses onto an ancestor of it. `./.` is the one that
      # was measured; the rest are the same defect with different arithmetic,
      # and a guard that keys on one string is how this happened in the first
      # place.
      const degenerate = ["./.", "./", "a/..", ".//.", "..", "../..",
                          "../sib/.."]
      for value in degenerate:
        writeLock(value)
        let res = runShell(shellCommand([repro, "develop", "--all", "--reset",
          "--workspace-root=" & workspaceRoot]))
        checkpoint("develop --all --reset with path='" & value & "': " &
          res.output)

        # The DECISIVE assertions first, and they are about the disk. `.git`
        # leads: it is the one the delete took that no re-clone brings back.
        check dirExists(workspaceRoot / ".git")
        check dirExists(workspaceRoot / "src")
        check fileExists(workspaceRoot / "src" / "code.txt")
        check fileExists(workspaceRoot / "PRECIOUS.txt")
        check fileExists(workspaceRoot / "repro.lock")
        if fileExists(workspaceRoot / "PRECIOUS.txt"):
          check readFile(workspaceRoot / "PRECIOUS.txt") == "must survive\n"

        # ...and the run FAILED, naming the offending value and a remedy. A
        # refusal that exited 0 would be the `repro remove` defect again.
        check res.code == 1
        check res.output.contains(value)
        check res.output.contains("repro lock refresh")

      # A path the lock boundary ACCEPTS — it is a real sibling shape, not a
      # collapse — but that lands outside the develop plane's documented
      # placement scope. Nothing refuses this at the reader (nor should:
      # `../name` is legitimate and the reader cannot know where the
      # workspace sits), so the placement proof is the only thing between a
      # lock and a `removeDir` on an arbitrary directory two levels up.
      block:
        let farHome = scratch / "far-home"
        createDir(farHome)
        writeFile(farHome / "not-ours.txt", "leave me\n")
        writeLock("../../far-home")
        let far = runShell(shellCommand([repro, "develop", "--all", "--reset",
          "--workspace-root=" & workspaceRoot]))
        checkpoint("develop --all --reset with path='../../far-home': " &
          far.output)
        check fileExists(farHome / "not-ours.txt")
        check far.code == 1
        check far.output.contains("outside the develop placement scope")
        # The scope is NAMED, so an operator can see what it is rather than
        # guessing, and `--into` is offered as the deliberate way out.
        check far.output.contains("--into")

      # The preview modes answer the same way. This is the half that made the
      # measured incident so much worse than a bad exit code: `--list` and
      # `--dry-run` both ANNOUNCED the workspace root as the node's checkout
      # target, so the operator was shown the plan, saw nothing alarming in
      # it, and then ran it.
      writeLock("./.")
      for mode in ["--list", "--dry-run"]:
        let preview = runShell(shellCommand([repro, "develop", "--all", mode,
          "--workspace-root=" & workspaceRoot]))
        checkpoint("develop --all " & mode & ": " & preview.output)
        check preview.code == 1
        check preview.output.contains("repro lock refresh")

      # And the constraint: the documented sibling topology still places a
      # sibling. Asserted last and asserted POSITIVELY — a boundary that
      # refused this would have "fixed" the defect by breaking the verb.
      writeLock("../sib")
      let sibling = runShell(shellCommand([repro, "develop", "--all",
        "--reset", "--workspace-root=" & workspaceRoot]))
      checkpoint("develop --all --reset with path='../sib': " &
        sibling.output)
      check dirExists(scratch / "sib" / ".git")
      check sibling.code == 0
      # The workspace root is untouched by the sibling placement, too.
      check dirExists(workspaceRoot / ".git")
      check fileExists(workspaceRoot / "PRECIOUS.txt")

  test "t_a_lock_supplied_revision_cannot_escape_the_producer_cache":
    ## W5 (third pass) — the segment ADJACENT to the one that was guarded.
    ##
    ## `validateLockedDeps` asked the traversal question of `path` and of
    ## `name`, and NOT of `coordinates.revision` — the next segment of the
    ## same expression, out of the same lock, reaching the same delete:
    ##
    ##   lockPinnedProducerCacheRoot(ws) / dep.name / revision
    ##     → removeDir(extendedPath(checkoutRoot))
    ##
    ## Which is the whole lesson of this file restated: a guard is not a
    ## property of a FIELD, it is a property of everything that reaches the
    ## delete, and stopping at the field the eye lands on leaves the one next
    ## to it open.
    ##
    ## Three things make it worse than it reads. The `\\?\` prefix confers
    ## nothing — `extendedPath` calls `normalizedPath(absolutePath(...))`, so
    ## Windows folds the `..` away BEFORE the prefix goes on. Nothing else
    ## asks: `parseLockedDependencies` applies no format check at all, and
    ## `isExactLockedRevision` guards the DEVELOP plane, not this one. And the
    ## `removeDir` runs BEFORE the fetch, so a revision no remote could ever
    ## serve is not a revision that is harmless — the fetch failing is what
    ## the delete has already happened for.
    ##
    ## Asserted at the READER, because that is where the guard is: a lock
    ## carrying such a revision is refused by every verb that reads a lock,
    ## whether or not that verb would have gone on to build a cache
    ## directory. The accepted direction is asserted last — an ordinary
    ## revision still places its checkout — because a rule that refused every
    ## revision would "fix" this by breaking every lock in existence.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let repro = requireReproBinary()
      let scratch = createTempDir("repro-pathguard-lockrev-", "")
      defer: removeDir(scratch)

      let depOrigin = scratch / "origin-dep.git"
      seedOrigin(gitBin, depOrigin, scratch / "seed-dep")
      let depSha = requireGit(gitBin,
        "-C " & q(scratch / "seed-dep") & " rev-parse HEAD").strip()
      check depSha.len == 40

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      discard requireGit(gitBin, "init --quiet -b main " & q(workspaceRoot))
      writeFile(workspaceRoot / "PRECIOUS.txt", "must survive\n")

      # The directory the traversing revision below actually resolves to.
      # `<ws>/.repro/cross-repo-producers/dep/../../../../victim` pops `dep`,
      # `cross-repo-producers`, `.repro` and `workspace` — landing beside the
      # workspace, on a directory this run has no business touching.
      let victim = scratch / "victim"
      createDir(victim)
      writeFile(victim / "not-ours.txt", "leave me\n")

      proc writeLock(revision: string) =
        # `path` is `../sib` — the DOCUMENTED sibling placement, accepted by
        # the path guard on purpose. So the only thing under test here is the
        # revision: a lock that is otherwise entirely well-formed.
        writeFile(workspaceRoot / "repro.lock",
          "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
          "[lock]\nplatform = \"amd64-linux\"\noptimal = false\n" &
          "inputs_digest = \"fnv1a64:0000000000000000\"\n" &
          "variants = []\npackages = []\n" &
          "deps = [{ name = \"dep\", path = \"../sib\", " &
          "coord_kind = \"vcs\", url = \"" & fileUrl(depOrigin) & "\", " &
          "ref = \"main\", revision = \"" & revision & "\", " &
          "integrity = \"git-sha1:" & depSha & "\", version = \"\", " &
          "visibility = \"public\", participation = \"\", " &
          "depends = \"\", groups = \"\" }]\n")

      # The traversal question, asked directly of the values a revision field
      # can carry. `..` is not merely unusual in a revision: `git
      # check-ref-format` forbids it in a refname outright, so nothing this
      # refuses was ever a revision a remote could serve.
      check pathTraversalRejection(depSha).len == 0
      check pathTraversalRejection("main").len == 0
      check pathTraversalRejection("refs/heads/main").len == 0
      check pathTraversalRejection("v1.2.3").len == 0
      check pathTraversalRejection("../../../../victim").len > 0
      check pathTraversalRejection("..").len > 0
      check pathTraversalRejection("a/../../b").len > 0

      const hostile = ["../../../../victim", "..", "a/../../b"]
      # BOTH a read-only verb and the destructive one, because the guard is at
      # the reader: `--list` never deletes anything, and it must refuse all
      # the same, or the refusal is a property of `--reset` rather than of the
      # lock.
      for value in hostile:
        writeLock(value)
        for mode in ["--list", "--reset"]:
          let res = runShell(shellCommand([repro, "develop", "--all", mode,
            "--workspace-root=" & workspaceRoot]))
          checkpoint("develop --all " & mode & " with revision='" & value &
            "': " & res.output)

          # The disk first. Nothing outside the workspace was touched, and the
          # workspace itself is intact.
          check fileExists(victim / "not-ours.txt")
          check fileExists(workspaceRoot / "PRECIOUS.txt")
          check dirExists(workspaceRoot / ".git")

          # ...and the run FAILED, naming the offending value and a remedy. A
          # lock is machine-written, so the remedy is the command that
          # rewrites it.
          check res.code == 1
          check res.output.contains(value)
          check res.output.contains("repro lock refresh")
          # The offender is the DEPENDENCY, not just the string — an operator
          # holding a 300-dep lock needs to know which line to look at.
          check res.output.contains("'dep'")

      # An absolute revision is refused too, for the same reason it is refused
      # as a path: joined onto the cache root it discards it. Written
      # separately because the spelling is per-platform.
      let absoluteRevision =
        when defined(windows): "C:/somewhere/else"
        else: "/somewhere/else"
      writeLock(absoluteRevision)
      let absRes = runShell(shellCommand([repro, "develop", "--all", "--list",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("develop --all --list with revision='" & absoluteRevision &
        "': " & absRes.output)
      check absRes.code == 1
      check absRes.output.contains(absoluteRevision)
      check absRes.output.contains("repro lock refresh")

      # The constraint, asserted positively and asserted last: a real revision
      # still runs, and still places the sibling the lock asks for.
      writeLock(depSha)
      let ok = runShell(shellCommand([repro, "develop", "--all", "--reset",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("develop --all --reset with revision=<real sha>: " & ok.output)
      check ok.code == 0
      check dirExists(scratch / "sib" / ".git")
      check fileExists(victim / "not-ours.txt")
      check fileExists(workspaceRoot / "PRECIOUS.txt")

  test "t_a_fetch_url_cannot_slug_its_way_out_of_the_shared_clone_cache":
    ## W5 (third pass) — the delete-steering lock field that is NOT a path,
    ## and the one place a path rule would have been the wrong rule.
    ##
    ## A fetch URL becomes a DIRECTORY: `urlSlug` maps it to a cache-relative
    ## slug, `sharedBarePath` / `manifestCachePath` join that onto the cache
    ## root, and three cleanup paths `removeDir` the result when the clone
    ## into it FAILS — `refreshSharedBare`, `ensureManifestCache`, and the
    ## `refresh-bare` executor in `git_actions`. Same shape as every other
    ## case in this file: the delete lives on the failure branch, so a URL
    ## that cannot be cloned at all is precisely the URL that reaches it.
    ##
    ## `sanitizeSlugSegment` kept `-._` and alnum, so a `..` path segment
    ## survived into the slug verbatim. Measured on `d0c6ad8f`, against a
    ## cache root of `…\Temp\w5cache`:
    ##
    ##   https://h/../../../victim.git → C:\Users\<u>\AppData\Local\victim.git
    ##   git@h:../../victim.git        → …\AppData\Local\Temp\victim.git
    ##
    ## and the escape is complete before any `extendedPath` is involved,
    ## because `os./` folds the `..` away on the way in.
    ##
    ## WHY THE FIX IS NOT AT THE LOCK BOUNDARY, which is where `path`, `name`
    ## and `revision` are all answered. Two reasons, and the test asserts
    ## both. A `..` segment is LEGAL in a remote path — it names something on
    ## the server and need never become a local directory — so refusing it
    ## upstream refuses a legitimate remote to protect a local join. And the
    ## same slug is reached from a MANIFEST `repo.remote` (via `cloneUrlFor`)
    ## which never passes through `validateLockedDeps` at all, so a rule there
    ## would cover one of the two producers and leave the other open. The rule
    ## therefore lives in `sanitizeSlugSegment`, where the URL BECOMES a path:
    ## total, one funnel, every caller and every plane at once.
    let cacheRoot = createTempDir("repro-pathguard-slug-", "")
    defer: removeDir(cacheRoot)
    let normRoot = os.normalizedPath(absolutePath(cacheRoot))

    const hostile = [
      "https://h/../../../victim.git",
      "git@h:../../victim.git",
      "ssh://git@h:22/../../victim.git",
      "https://h/a/../b.git",
      "https://../x.git",
      "file:///tmp/../../victim.git",
      "/tmp/../../victim.git",
    ]
    for url in hostile:
      let slug = urlSlug(url)
      checkpoint("urlSlug(" & url & ") = " & slug)
      # No segment may be NAVIGATION. `.` is included: it is inert on its own
      # but it is the same class of thing, and a slug is a name, not a route.
      for raw in slug.split({'/', '\\'}):
        let segment = raw.strip()
        check segment != ".."
        check segment != "."
      # ...and the property that actually matters, stated about the path
      # rather than about the string: both consumers land BENEATH the cache
      # root they were given.
      for computed in [sharedBarePath(cacheRoot, url),
                       manifestCachePath(cacheRoot, url)]:
        let normComputed = os.normalizedPath(absolutePath(computed))
        checkpoint("  → " & normComputed)
        check normComputed.len > normRoot.len
        check normComputed.startsWith(normRoot & $DirSep)

    # The constraint. A slug is a CACHE KEY, so changing it for an ordinary
    # remote silently orphans every bare clone already on disk — and a rule
    # that sanitized more than it had to would do exactly that. These are the
    # spellings `urlSlug`'s own doc comment promises, asserted byte-for-byte.
    check urlSlug("https://github.com/org/repo.git") == "github.com/org/repo.git"
    check urlSlug("git@github.com:org/repo.git") == "github.com/org/repo.git"
    check urlSlug("file:///tmp/origin-lib-a.git") == "_local_/tmp/origin-lib-a.git"
    check urlSlug("/tmp/origin-lib-a.git") == "_local_/tmp/origin-lib-a.git"
    # And the edge the rule is deliberately narrow about: a segment that
    # CONTAINS dots is an ordinary directory name and is left alone. Only a
    # segment that is NOTHING BUT dots is navigation — including `...` and
    # longer, which Win32 strips trailing dots from and can collapse into
    # `..`.
    check urlSlug("https://h/a..b/..z/_../c.git") == "h/a..b/..z/_../c.git"
    check urlSlug("https://h/.../c.git") == "h/___/c.git"

    # WHAT THIS BLOCK DOES NOT ASSERT, said out loud because four spellings
    # checked byte-for-byte look like an injectivity claim and are not one.
    # `urlSlug` is many-to-one and always has been (`a:b`, `a_b` and `a@b` are
    # three URLs and one slug), and the rewrite above WIDENS that: `..` and a
    # literal `__` now share a slug, as do `.` and `_`. Asserted here so the
    # collision is a recorded property rather than a surprise, and so that
    # narrowing it later is a deliberate change with a visible cost — every
    # slug that moves orphans the bare clone already on disk under the old
    # name. Containment is unaffected: both members of each pair are inert.
    check urlSlug("https://h/../victim.git") == urlSlug("https://h/__/victim.git")
    check urlSlug("https://h/./victim.git") == urlSlug("https://h/_/victim.git")
    check urlSlug("https://h/.../c.git") == urlSlug("https://h/___/c.git")

  test "t_a_hostile_fetch_url_deletes_a_real_directory_before_this_rule":
    ## W5 (fifth pass) — case 10's property, driven through the REAL cleanup
    ## instead of asserted about the string.
    ##
    ## Case 10 above is a unit test: it calls `urlSlug` / `sharedBarePath` /
    ## `manifestCachePath` against a temp directory that is never used as a
    ## cache, so nothing in it ever reaches a `removeDir`. That is enough to
    ## pin the slug's shape and not enough to show the guard prevents
    ## anything — the same gap that made an earlier `dep.name` case
    ## unconvincing. This case closes it by handing a hostile URL to the real
    ## `refreshSharedBare` and the real `ensureManifestCache` with a real
    ## `git` and a real victim directory on disk.
    ##
    ## The mechanism, which is what makes an offline test possible at all:
    ## the victim's own EXISTENCE is what fails the clone. `git clone` refuses
    ## a destination that exists and is non-empty, the proc's failure branch
    ## then runs `removeDir` on that same computed destination, and the victim
    ## is gone. No network, no server, no timeout — the whole incident is
    ## local. Measured on `d0c6ad8f`, both arms:
    ##
    ##   computed = <enclosing>\w5victimalpha.git   (== the victim)
    ##   ok       = false
    ##   fatal: destination path '<victim>' already exists and is not empty
    ##   victim dir exists = FALSE   sentinel exists = FALSE
    ##
    ## and with `sanitizeSlugSegment`'s rule in place the computed path is
    ## `<cacheRoot>\_local_\x\__\__\__\w5victimalpha.git`, the clone fails for
    ## the ordinary reason (the URL names no repository), and the victim is
    ## untouched.
    ##
    ## THE DECOY IS THE NON-VACUITY ASSERTION. A test that only checked "the
    ## victim survived" would also pass if the cleanup `removeDir` never ran
    ## at all. So the computed path is pre-created with a marker before the
    ## call, and asserted GONE after it: that is a positive observation that
    ## the delete fired and that it pointed inside the cache root. The victim
    ## check and the decoy check together say the delete happened AND landed
    ## in the right place.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pathguard-slug-e2e-", "")
      defer: removeDir(scratch)

      # Each arm gets its OWN enclosing directory. The escape lands exactly
      # one level above the cache root, so two arms sharing a parent would be
      # aiming at each other's victim.
      for (arm, victimName, viaManifestCache) in [
          ("refreshSharedBare", "w5victimalpha.git", false),
          ("ensureManifestCache", "w5victimbeta.git", true)]:
        let enclosing = scratch / arm
        let cacheRoot = enclosing / "cache"
        createDir(cacheRoot)

        # The victim: a plain directory one level ABOVE the cache root, named
        # for the URL's last segment. Deliberately NOT a git dir — a git dir
        # would send both procs down their fetch-if-present branch, which
        # deletes nothing, and the case would pass without exercising the
        # cleanup at all.
        let victim = enclosing / victimName
        createDir(victim)
        writeFile(victim / "PRECIOUS.txt", "must survive\n")

        # Three `..` is exactly the depth that walks `<cacheRoot>/_local_/x`
        # back out to `enclosing`. `file://` keeps it offline and keeps git's
        # failure immediate.
        let url = "file:///x/../../../" & victimName
        let computed =
          if viaManifestCache: manifestCachePath(cacheRoot, url)
          else: sharedBarePath(cacheRoot, url)
        let normComputed = os.normalizedPath(absolutePath(computed))
        let normCacheRoot = os.normalizedPath(absolutePath(cacheRoot))
        checkpoint(arm & ": url=" & url)
        checkpoint("  computed=" & normComputed)

        # The decoy — see the header. Created at whatever the code under test
        # computes, so it is the victim itself when the rule is absent.
        createDir(computed)
        writeFile(computed / "decoy.txt", "the cleanup should take this\n")

        let res =
          if viaManifestCache: ensureManifestCache(gitBin, cacheRoot, url)
          else: refreshSharedBare(gitBin, cacheRoot, url)
        checkpoint("  ok=" & $res.ok & " diagnostic=" & res.diagnostic.strip())

        # The clone failed, so control reached the cleanup branch. Asserted
        # rather than assumed: a clone that unexpectedly SUCCEEDED would skip
        # the `removeDir` entirely and leave every check below true for the
        # wrong reason.
        check not res.ok

        # ...the delete fired, and it landed on the computed path.
        check not dirExists(computed)

        # ...and the computed path was inside the cache root, so what it took
        # was the decoy and not the victim.
        check normComputed.len > normCacheRoot.len
        check normComputed.startsWith(normCacheRoot & $DirSep)
        check dirExists(victim)
        check fileExists(victim / "PRECIOUS.txt")
        if fileExists(victim / "PRECIOUS.txt"):
          check readFile(victim / "PRECIOUS.txt") == "must survive\n"

  test "t_the_path_identity_primitive_resolves_what_a_lexical_fold_cannot":
    ## W8-R1 / W8-R2, at unit level, on the one canonicalization the five
    ## deleting consumers now share.
    ##
    ## This case exists because the five end-to-end cases below can only show
    ## that SOMETHING refused. They cannot show WHY, they cannot reach the
    ## failure policy (a path that will not resolve is not a thing a CLI
    ## fixture can conjure on demand), and they cannot state the R2 property
    ## at all on a host whose volume happens to be case-insensitive in the
    ## direction that hides it. So the primitive is asserted directly, and
    ## the pre-state — that the LEXICAL comparison W5 shipped answers
    ## differently — is asserted alongside every verdict, so no assertion here
    ## can pass for a reason that has nothing to do with resolution.
    let scratch = createTempDir("repro-pathguard-identity-", "")
    defer: removeDir(scratch)
    var links: seq[string]
    defer:
      for p in links: removeDirReparsePoint(p)

    let parent = scratch / "parent"
    let workspaceRoot = parent / "workspace"
    createDir(workspaceRoot / "inner")
    createDir(parent / "realsib")

    # --- resolution of an ORDINARY path is the identity -------------------
    let plain = resolveCanonicalPath(workspaceRoot)
    check plain.status == prsResolved
    check plain.missing == 0
    check plain.existing == plain.path

    # --- a path that does not exist yet is NOT a failure ------------------
    #
    # The policy that makes every other one affordable. A clone target does
    # not exist before the clone, and a rule that refused it would refuse
    # every create. The deepest EXISTING ancestor is resolved and the missing
    # tail re-attached, which is sound precisely because a component that does
    # not exist cannot be a reparse point.
    let unborn = resolveCanonicalPath(workspaceRoot / "not-yet" / "deeper")
    check unborn.status == prsResolved
    check unborn.missing == 2
    check unborn.existing == plain.path
    check unborn.path == plain.path / "not-yet" / "deeper"

    # --- and an EMPTY path is a failure, not an absence -------------------
    #
    # The campaign's recurring root defect is an error read as an absence, so
    # the two are separate values here and the reason is carried rather than
    # dropped.
    let empty = resolveCanonicalPath("")
    check empty.status == prsFailed
    check empty.reason.len > 0

    # --- and REFUSE is what a failure becomes at the containment layer ----
    #
    # The policy the whole change rests on: an operation that cannot establish
    # where its target is must not proceed, because the next statement is an
    # irreversible delete. Asserted in both directions, since either side can
    # be the one that will not resolve.
    check fsContainment(workspaceRoot, "").verdict == fcUnresolvable
    check fsContainment("", workspaceRoot).verdict == fcUnresolvable
    check fsContainment("", workspaceRoot).reason.len > 0

    when defined(windows):
      # A NETWORK path that will not answer — the one non-trivial failure mode
      # that can be produced without special privileges or a timeout. The host
      # is the loopback (so there is no DNS lookup to hang on) and the share
      # does not exist, which Windows answers immediately with
      # `ERROR_BAD_NET_NAME`. It must REFUSE and not read as an absence: an
      # absence would resolve to the deepest existing ancestor, and a network
      # path has none.
      const unreachableUnc = r"\\127.0.0.1\no-such-share-w8\x"
      let unreachable = resolveCanonicalPath(unreachableUnc)
      check unreachable.status == prsFailed
      check unreachable.reason.len > 0
      check fsContainment(unreachableUnc, workspaceRoot).verdict ==
        fcUnresolvable

    # --- the negative direction, first --------------------------------------
    #
    # Asserted BEFORE the reparse points, because a rule that refuses
    # everything "fixes" W8 by breaking `repro develop --all` for every node
    # locked at the documented default placement.
    check fsContainment(parent / "realsib", workspaceRoot).verdict == fcDisjoint
    check fsContainment(workspaceRoot / "inner", workspaceRoot).verdict ==
      fcBeneath
    check fsContainment(parent, workspaceRoot).verdict == fcContainsRoot
    check fsContainment(workspaceRoot, workspaceRoot).verdict == fcSameDirectory

    # --- W8-R1: both reparse tags -------------------------------------------
    var coveredTags = 0
    for kind in [rkJunction, rkSymlink]:
      let sib = parent / ("sib-" & reparseKindName(kind))
      let made = makeDirReparsePoint(kind, sib, workspaceRoot)
      if not made.ok:
        checkpoint("reparse tag '" & reparseKindName(kind) &
          "' is not available on this host: " & made.why)
        continue
      links.add(sib)
      inc coveredTags
      checkpoint("reparse tag: " & reparseKindName(kind))

      # PRE-STATE. The lexical rule W5 shipped calls this a SIBLING, which is
      # accepted by design — that is the whole defect, and asserting it here
      # is what stops the verdict below from being true for some other reason.
      check lexicallyDisjoint(sib, workspaceRoot)
      check symlinkExists(sib)
      # ...and the stdlib's two "resolve" procs do not help, which is why the
      # primitive is a Win32 call rather than a call to one of them.
      when defined(windows):
        check (try: expandFilename(sib) except CatchableError: "") !=
          os.normalizedPath(absolutePath(workspaceRoot))

      # The verdict.
      let viaLink = fsContainment(sib, workspaceRoot)
      check viaLink.verdict == fcSameDirectory
      check viaLink.target == plain.path

      # ...and a reparse point aimed at the workspace's PARENT contains it.
      let up = parent / ("up-" & reparseKindName(kind))
      let madeUp = makeDirReparsePoint(kind, up, parent)
      if madeUp.ok:
        links.add(up)
        check lexicallyDisjoint(up, workspaceRoot)
        check fsContainment(up, workspaceRoot).verdict == fcContainsRoot

      # ...and one aimed at a genuine sibling stays DISJOINT. A rule that
      # refused every reparse point would pass every assertion above and
      # break this one, which is the difference between resolving a path and
      # banning a filesystem feature.
      let harmless = parent / ("harmless-" & reparseKindName(kind))
      let madeHarmless = makeDirReparsePoint(kind, harmless, parent / "realsib")
      if madeHarmless.ok:
        links.add(harmless)
        check fsContainment(harmless, workspaceRoot).verdict == fcDisjoint

    # At least one tag must have been exercised. On Windows both are expected;
    # on Linux the junction arm is a documented platform absence, not a skip
    # of the property.
    check coveredTags > 0
    when defined(windows):
      check coveredTags == 2

    # --- W8-R2: the same comparison, under case ---------------------------
    #
    # Stated as a PROPERTY OF THE FILESYSTEM rather than as a platform
    # assumption. Case-insensitivity is per-VOLUME on Windows and per-mount on
    # Linux, so this asserts what the filesystem actually did with the two
    # spellings rather than what the OS is guessed to do with them:
    #
    #   * if the upper-case spelling names the SAME directory (the volume is
    #     case-insensitive), `fsContainment` must say so — while the lexical
    #     compare says the opposite, which is the latent defect;
    #   * if it names NOTHING (the volume is case-sensitive), the two are
    #     genuinely different paths and nothing is claimed.
    #
    # No `cmpIgnoreCase`, and no `GetVolumeInformationW` /
    # `FILE_CASE_SENSITIVE_SEARCH` query: the canonicalization answers it, and
    # `(volume, file id)` / `(st_dev, st_ino)` answers it where the
    # canonicalization cannot (`realpath` does not case-fold).
    let shouted = parent / "WORKSPACE"
    if dirExists(shouted):
      # PRE-STATE: byte-wise, the two spellings disagree. This is the
      # comparison `containmentInWorkspaceRoot` and
      # `developPlacementRejection` both used to make.
      check os.normalizedPath(absolutePath(shouted)) !=
        os.normalizedPath(absolutePath(workspaceRoot))
      check fsContainment(shouted, workspaceRoot).verdict == fcSameDirectory
      let same = sameFsObject(shouted, workspaceRoot)
      check same.ok
      check same.same
      checkpoint("this volume is case-INSENSITIVE; the R2 property is live " &
        "here and is asserted")
    else:
      checkpoint("this volume is case-SENSITIVE (" & shouted &
        " names nothing); R2 has no two spellings to confuse here")
      # ...and the identity layer must not invent a match out of two genuinely
      # different directories.
      check fsContainment(shouted, workspaceRoot).verdict != fcSameDirectory

  test "t_develop_all_reset_refuses_a_reparse_point_aimed_at_the_workspace":
    ## W8-R1 — THE reproduction, end to end, through the real CLI, for the
    ## third of the five deleting consumers (`developPlacementRejection`).
    ##
    ## Measured on `09324b61`, for a junction and for a directory symlink
    ## alike:
    ##
    ##   mklink /J …\parent\sib …\parent\workspace
    ##   repro.lock:  deps = [{ …, path = "../sib", … }]
    ##   repro develop --all --reset --workspace-root=…\parent\workspace
    ##   EXIT=0  — and the workspace is reduced to `.repro`: `.git`,
    ##             `PRECIOUS.txt`, `src\` and `repro.lock` are all gone.
    ##
    ## The EXIT CODE is the sharpest part of it. This was not a guard that
    ## refused too little; it was an irreversible delete that REPORTED having
    ## done the right thing — worse than the `./.` case W5 fixed, which at
    ## least exited 1.
    ##
    ## `../sib` is accepted BY DESIGN and that is what made it invisible: a
    ## sibling is a peer of the workspace and the develop plane's documented
    ## default placement (CLI/develop.md §"Checkout Placement"). No amount of
    ## string folding can tell that particular sibling from the workspace
    ## itself, which is why the fix is a filesystem question and not a wider
    ## lexical rule.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let repro = requireReproBinary()
      let scratch = createTempDir("repro-pathguard-reparse-develop-", "")
      defer: removeDir(scratch)
      var links: seq[string]
      defer:
        for p in links: removeDirReparsePoint(p)

      let depOrigin = scratch / "origin-dep.git"
      seedOrigin(gitBin, depOrigin, scratch / "seed-dep")
      let depSha = requireGit(gitBin,
        "-C " & q(scratch / "seed-dep") & " rev-parse HEAD").strip()
      check depSha.len == 40

      proc writeLock(workspaceRoot, checkoutPath: string) =
        writeFile(workspaceRoot / "repro.lock",
          "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
          "[lock]\nplatform = \"amd64-linux\"\noptimal = false\n" &
          "inputs_digest = \"fnv1a64:0000000000000000\"\n" &
          "variants = []\npackages = []\n" &
          "deps = [{ name = \"dep\", path = \"" & checkoutPath & "\", " &
          "coord_kind = \"vcs\", url = \"" & fileUrl(depOrigin) & "\", " &
          "ref = \"main\", revision = \"" & depSha & "\", " &
          "integrity = \"git-sha1:" & depSha & "\", version = \"\", " &
          "visibility = \"public\", participation = \"\", " &
          "depends = \"\", groups = \"\" }]\n")

      proc seedWorkspace(workspaceRoot: string) =
        createDir(workspaceRoot / "src")
        discard requireGit(gitBin, "init --quiet -b main " & q(workspaceRoot))
        writeFile(workspaceRoot / "PRECIOUS.txt", "must survive\n")
        writeFile(workspaceRoot / "src" / "code.txt", "source\n")
        writeLock(workspaceRoot, "../sib")

      var coveredTags = 0
      for kind in [rkJunction, rkSymlink]:
        let parent = scratch / ("hostile-" & reparseKindName(kind)) / "parent"
        let workspaceRoot = parent / "workspace"
        seedWorkspace(workspaceRoot)
        let sib = parent / "sib"
        let made = makeDirReparsePoint(kind, sib, workspaceRoot)
        if not made.ok:
          checkpoint("reparse tag '" & reparseKindName(kind) &
            "' is not available on this host: " & made.why)
          continue
        links.add(sib)
        inc coveredTags
        checkpoint("reparse tag: " & reparseKindName(kind))

        # PRE-STATE, so this case cannot pass for the wrong reason: the
        # reparse point really exists, and the LEXICAL rule really does read
        # it as an ordinary accepted sibling.
        check symlinkExists(sib)
        check lexicallyDisjoint(sib, workspaceRoot)

        let res = runShell(shellCommand([repro, "develop", "--all", "--reset",
          "--workspace-root=" & workspaceRoot]))
        checkpoint("develop --all --reset through a " &
          reparseKindName(kind) & ": " & res.output)

        # The DECISIVE assertions, and they are about the disk. `.git` leads:
        # it is the one the delete took that no re-clone brings back.
        check dirExists(workspaceRoot / ".git")
        check dirExists(workspaceRoot / "src")
        check fileExists(workspaceRoot / "src" / "code.txt")
        check fileExists(workspaceRoot / "PRECIOUS.txt")
        check fileExists(workspaceRoot / "repro.lock")
        if fileExists(workspaceRoot / "PRECIOUS.txt"):
          check readFile(workspaceRoot / "PRECIOUS.txt") == "must survive\n"

        # ...and the run REFUSED rather than reporting success. Exit 0 with
        # the workspace intact would mean the delete simply missed, not that
        # anything decided.
        check res.code == 1
        check res.output.contains("IS the workspace root")

      check coveredTags > 0
      when defined(windows):
        check coveredTags == 2

      # THE NEGATIVE DIRECTION, and it is not optional. `../sib` is the
      # develop plane's DOCUMENTED DEFAULT placement, so a fix that refuses it
      # breaks `repro develop --all` for every node locked at
      # `path = "../name"` — exactly the regression W5's third round shipped
      # and had to repair. A genuine sibling, no reparse point:
      block:
        let parent = scratch / "legitimate" / "parent"
        let workspaceRoot = parent / "workspace"
        seedWorkspace(workspaceRoot)
        let placed = runShell(shellCommand([repro, "develop", "--all",
          "--reset", "--workspace-root=" & workspaceRoot]))
        checkpoint("develop --all --reset onto a REAL sibling: " &
          placed.output)
        check placed.code == 0
        check dirExists(parent / "sib" / ".git")
        check dirExists(workspaceRoot / ".git")
        check fileExists(workspaceRoot / "PRECIOUS.txt")

        # ...and again, now that the sibling EXISTS — the `--reset` route,
        # which is the one that deletes. A rule that only allowed the create
        # would still have broken the verb on every subsequent run.
        let again = runShell(shellCommand([repro, "develop", "--all",
          "--reset", "--workspace-root=" & workspaceRoot]))
        checkpoint("develop --all --reset onto an EXISTING sibling: " &
          again.output)
        check again.code == 0
        check dirExists(parent / "sib" / ".git")
        check dirExists(workspaceRoot / ".git")
        check fileExists(workspaceRoot / "PRECIOUS.txt")

  test "t_clone_cleanup_and_force_reset_resolve_a_reparse_point_target":
    ## W8-R1 for the two consumers in `git_actions.nim` — the FIRST
    ## (`removeCloneTargetSafely`) and the SECOND (`executeForceReset`).
    ##
    ## They share one `containmentInWorkspaceRoot`, so one resolution serves
    ## both, but they are asserted separately because they REFUSE
    ## differently and the difference is deliberate: the clone cleanup
    ## refuses outright, while the force-reset runs the half that is in
    ## bounds (`git reset --hard`, bounded by git's TRACKED set) and skips the
    ## half that is not (`git clean -ffdx`, bounded by the DIRECTORY). A fix
    ## that collapsed them into one refusal would break `repro sync
    ## --force-sync` on the root repo, which is the narrowing W5 landed.
    ##
    ## Driven through the real engine against a real `git`, with the reparse
    ## point named as the payload's `repoPath` — the shape a lock records and
    ## the placement plane hands over.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pathguard-reparse-vcs-", "")
      defer: removeDir(scratch)
      var links: seq[string]
      defer:
        for p in links: removeDirReparsePoint(p)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
      installGitVcsExecutor()

      let origin = scratch / "origin.git"
      seedOrigin(gitBin, origin, scratch / "seed")
      var config = defaultBuildEngineConfig(scratch / "engine-cache")
      config.suppressTrace = true
      config.fallbackToRunQuotaBypass = true

      var coveredTags = 0
      for kind in [rkJunction, rkSymlink]:
        let tag = reparseKindName(kind)

        # ---- consumer 1: the half-clone cleanup ---------------------------
        #
        # The workspace root is deliberately NOT a git checkout: that is what
        # sends `executeClone` down its half-clone cleanup branch, which is
        # the branch holding the `removeDir`. A `.git` there would take the
        # `clone-target-exists` early return instead and this arm would prove
        # nothing.
        block:
          let parent = scratch / ("clone-" & tag) / "parent"
          let workspaceRoot = parent / "workspace"
          createDir(workspaceRoot / "precious-dir")
          writeFile(workspaceRoot / "precious.txt", "must survive\n")
          writeFile(workspaceRoot / "precious-dir" / "inner.txt", "also\n")
          let sib = parent / "sib"
          let made = makeDirReparsePoint(kind, sib, workspaceRoot)
          if not made.ok:
            checkpoint("reparse tag '" & tag &
              "' is not available on this host: " & made.why)
          else:
            links.add(sib)
            inc coveredTags
            check symlinkExists(sib)
            check lexicallyDisjoint(sib, workspaceRoot)

            var action = gitCloneAction("reparse-clone-" & tag, identity,
              remoteUrl = fileUrl(origin),
              repoPath = ".." / "sib",
              receiptPath = ".repro" / ("reparse-" & tag & ".receipt"),
              revision = "main")
            action.cwd = workspaceRoot
            let res = runBuild(graph([action]), config)
            check res.results.len == 1
            checkpoint("clone through a " & tag & ": " &
              res.results[0].reason & " / " & res.results[0].stderr)
            check res.results[0].status notin
              {asSucceeded, asCacheHit, asUpToDate}
            check dirExists(workspaceRoot)
            check fileExists(workspaceRoot / "precious.txt")
            check fileExists(workspaceRoot / "precious-dir" / "inner.txt")
            if fileExists(workspaceRoot / "precious.txt"):
              check readFile(workspaceRoot / "precious.txt") ==
                "must survive\n"
            let diag = res.results[0].reason & "\n" & res.results[0].stderr
            check diag.contains("RESOLVES TO the workspace root")

        # ---- consumer 2: the force-reset --------------------------------
        #
        # Here the workspace root IS a git checkout, which is what makes it a
        # legal force-reset target as far as every check except the
        # containment proof is concerned. Before resolution the target read as
        # a DISJOINT sibling, so `git clean -ffdx` ran in the workspace root
        # and took every untracked file in it.
        block:
          let parent = scratch / ("reset-" & tag) / "parent"
          let workspaceRoot = parent / "workspace"
          createDir(parent)
          discard requireGit(gitBin, "clone --quiet " & q(fileUrl(origin)) &
            " " & q(workspaceRoot))
          writeFile(workspaceRoot / "PRECIOUS-UNTRACKED.txt", "must survive\n")
          createDir(workspaceRoot / "sibling-checkout")
          writeFile(workspaceRoot / "sibling-checkout" / "inner.txt", "also\n")
          writeFile(workspaceRoot / "seed.txt", "local edit\n")
          let sha = requireGit(gitBin,
            "-C " & q(workspaceRoot) & " rev-parse HEAD").strip()
          let sib = parent / "sib"
          let made = makeDirReparsePoint(kind, sib, workspaceRoot)
          if made.ok:
            links.add(sib)
            check symlinkExists(sib)
            check lexicallyDisjoint(sib, workspaceRoot)

            var action = gitForceResetAction("reparse-reset-" & tag, identity,
              revision = sha,
              repoPath = ".." / "sib",
              receiptPath = ".repro" / ("reparse-reset-" & tag & ".receipt"))
            action.cwd = workspaceRoot
            let res = runBuild(graph([action]), config)
            check res.results.len == 1
            checkpoint("force-reset through a " & tag & ": " &
              res.results[0].reason & " / " & res.results[0].stderr)

            # The clean was SKIPPED and the row says so.
            #
            # Asserted on `stderr` rather than on the structured `reason`,
            # and that is a fact about the ENGINE rather than a preference:
            # `completeSuccess(..., "builtin")`
            # (`repro_build_engine.nim`:6589) OVERWRITES the reason of every
            # action that succeeds, so the executor's
            # `force-reset-workspace-root-clean-skipped` marker never reaches
            # a `runBuild` caller. It reaches the OPERATOR — the CLI prints
            # `stderr`, which is what
            # `t_force_sync_on_the_workspace_root_skips_the_clean_and_says_so`
            # asserts end to end — so the user-visible half is intact. Noted
            # here because a case asserting the reason would go green for the
            # wrong reason the day the executor stopped setting it.
            check res.results[0].status in
              {asSucceeded, asCacheHit, asUpToDate}
            let notice = res.results[0].reason & " " & res.results[0].stderr
            check notice.contains("did NOT run `git clean -ffdx`")
            check notice.contains("the target is the workspace root")
            # ...and what `clean -ffdx` in the workspace root would have taken
            # is still there. The sibling checkout leads: it is not the
            # target, not the root repo's own tree, and not something a
            # force-reset was ever asked to touch.
            check dirExists(workspaceRoot / "sibling-checkout")
            check fileExists(workspaceRoot / "sibling-checkout" / "inner.txt")
            check fileExists(workspaceRoot / "PRECIOUS-UNTRACKED.txt")
            # ...while the half that IS in bounds still ran, so this is a
            # narrowing and not a dead end with a diagnostic.
            check fileExists(workspaceRoot / "seed.txt")
            if fileExists(workspaceRoot / "seed.txt"):
              check readFile(workspaceRoot / "seed.txt") != "local edit\n"

      check coveredTags > 0
      when defined(windows):
        check coveredTags == 2

      # THE NEGATIVE DIRECTION for these two consumers: a genuine sibling is
      # still cloned into, because that is the develop plane's documented
      # default placement and `containmentInWorkspaceRoot` is the proc that
      # broke it once already.
      block:
        let parent = scratch / "legitimate" / "parent"
        let workspaceRoot = parent / "workspace"
        createDir(workspaceRoot)
        var action = gitCloneAction("legit-sibling-clone", identity,
          remoteUrl = fileUrl(origin),
          repoPath = ".." / "sib",
          receiptPath = ".repro" / "legit.receipt",
          revision = "main")
        action.cwd = workspaceRoot
        let res = runBuild(graph([action]), config)
        check res.results.len == 1
        checkpoint("clone onto a REAL sibling: " & res.results[0].reason &
          " / " & res.results[0].stderr)
        check res.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
        check dirExists(parent / "sib" / ".git")

  test "t_workspace_disable_refuses_a_checkout_that_reparses_onto_the_root":
    ## W8-R1 for the FIFTH deleting consumer, `runWorkspaceDisableCommand`,
    ## end to end through the real CLI.
    ##
    ## The declared checkout path here is `only-mine` — an ORDINARY,
    ## workspace-relative, `..`-free spelling that every lexical rule in this
    ## repository accepts and should accept. What makes it dangerous is on
    ## disk: `<workspaceRoot>\only-mine` is a directory reparse point aimed at
    ## the workspace root, so `removeDir` walks into it and takes the
    ## workspace. That is why this case cannot be written with a degenerate
    ## path: the whole point is that the SPELLING is innocent.
    ##
    ## `--force` is deliberate, as in the `.` case above: it skips the
    ## work-loss gate, so what survives is attributed to the resolved own-tree
    ## question and to nothing else.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let repro = requireReproBinary()
      let scratch = createTempDir("repro-pathguard-reparse-disable-", "")
      defer: removeDir(scratch)
      var links: seq[string]
      defer:
        for p in links: removeDirReparsePoint(p)

      let onlyMineOrigin = scratch / "origin-only-mine.git"
      let keeperOrigin = scratch / "origin-keeper.git"
      seedOrigin(gitBin, onlyMineOrigin, scratch / "seed-only-mine")
      seedOrigin(gitBin, keeperOrigin, scratch / "seed-keeper")
      check requireGit(gitBin, "-C " & q(scratch / "seed-only-mine") &
          " rev-parse HEAD").strip() !=
        requireGit(gitBin, "-C " & q(scratch / "seed-keeper") &
          " rev-parse HEAD").strip()

      var coveredTags = 0
      for kind in [rkJunction, rkSymlink]:
        let tag = reparseKindName(kind)
        let workspaceRoot = scratch / ("ws-" & tag)
        createDir(workspaceRoot / "projects")
        createDir(workspaceRoot / "repos")
        writeFile(workspaceRoot / "precious.txt", "must survive\n")
        createDir(workspaceRoot / "precious-dir")
        writeFile(workspaceRoot / "precious-dir" / "inner.txt", "also\n")

        writeFragment(workspaceRoot / "repos" / "only-mine.toml",
          "only-mine", "only-mine")
        writeFragment(workspaceRoot / "repos" / "keeper.toml",
          "keeper", "keeper", remote = "keeper-origin")
        let remotes =
          "[[remote]]\nname = \"org\"\nfetch = \"" &
            fileUrl(onlyMineOrigin) & "\"\n\n" &
          "[[remote]]\nname = \"keeper-origin\"\nfetch = \"" &
            fileUrl(keeperOrigin) & "\"\n\n"
        writeFile(workspaceRoot / "projects" / "rooted.toml",
          "schema = \"reprobuild.workspace.project.v1\"\n\n" &
          "[project]\nname = \"rooted\"\ndefault_revision = \"main\"\n" &
          "trunk = \"main\"\n\n" & remotes &
          "includes = [\n  \"repos/only-mine.toml\",\n]\n")
        writeFile(workspaceRoot / "projects" / "keeper.toml",
          "schema = \"reprobuild.workspace.project.v1\"\n\n" &
          "[project]\nname = \"keeper\"\ndefault_revision = \"main\"\n" &
          "trunk = \"main\"\n\n" & remotes &
          "includes = [\n  \"repos/keeper.toml\",\n]\n")
        writeWorkspaceProjects(workspaceRoot, @["rooted", "keeper"])
        discard requireGit(gitBin, "clone --quiet " &
          q(fileUrl(keeperOrigin)) & " " & q(workspaceRoot / "keeper"))

        let hostile = workspaceRoot / "only-mine"
        let made = makeDirReparsePoint(kind, hostile, workspaceRoot)
        if not made.ok:
          checkpoint("reparse tag '" & tag &
            "' is not available on this host: " & made.why)
          continue
        links.add(hostile)
        inc coveredTags
        checkpoint("reparse tag: " & tag)

        # PRE-STATE. The declared spelling is one the OWN-TREE question
        # ACCEPTS — asserted against the real proc, so this case is not
        # testing a value that some other rule would have caught.
        check checkoutPathRejection("only-mine") == ""
        check symlinkExists(hostile)

        let res = runShell(shellCommand([repro, "workspace", "disable",
          "rooted", "--force", "--workspace-root=" & workspaceRoot]))
        checkpoint("workspace disable through a " & tag & ": " & res.output)

        # The workspace survived — `projects/` and `repos/` lead, because
        # they are what a `removeDir` through the reparse point takes first.
        check dirExists(workspaceRoot)
        check dirExists(workspaceRoot / "projects")
        check dirExists(workspaceRoot / "repos")
        check fileExists(workspaceRoot / "precious-dir" / "inner.txt")
        check fileExists(workspaceRoot / "precious.txt")
        if fileExists(workspaceRoot / "precious.txt"):
          check readFile(workspaceRoot / "precious.txt") == "must survive\n"
        # ...the still-enabled project's checkout is untouched...
        check dirExists(workspaceRoot / "keeper" / ".git")
        # ...and the run REFUSED this one removal and said so, rather than
        # exiting 0 over the wreckage.
        check res.code == 1
        check res.output.contains("refusing to remove the declared " &
          "checkout path 'only-mine'")
        check res.output.contains("resolves to the workspace root itself")
        check res.output.contains("left in place")

      check coveredTags > 0
      when defined(windows):
        check coveredTags == 2

  test "t_repro_remove_refuses_a_checkout_that_reparses_onto_the_root":
    ## W8-R1 for the FOURTH deleting consumer, `executeRemove`, end to end.
    ##
    ## `repro remove`'s RA-22 reachability GC reaches a checkout by two
    ## routes, and W5 established that they must be answered DIFFERENTLY:
    ## NAMED as the target the whole verb refuses before anything is mutated,
    ## because there is no partial execution of "remove this" that is correct;
    ## SWEPT IN through another target's `depends` closure only the one delete
    ## is skipped, because the operator asked for something else and that
    ## removal is legitimate. Both routes are driven here, because a
    ## resolution added to one of them and not the other would leave half the
    ## consumer where it was.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let repro = requireReproBinary()
      let scratch = createTempDir("repro-pathguard-reparse-remove-", "")
      defer: removeDir(scratch)
      var links: seq[string]
      defer:
        for p in links: removeDirReparsePoint(p)

      let hubOrigin = scratch / "origin-hub.git"
      let keeperOrigin = scratch / "origin-keeper.git"
      seedOrigin(gitBin, hubOrigin, scratch / "seed-hub")
      seedOrigin(gitBin, keeperOrigin, scratch / "seed-keeper")
      check requireGit(gitBin, "-C " & q(scratch / "seed-hub") &
          " rev-parse HEAD").strip() !=
        requireGit(gitBin, "-C " & q(scratch / "seed-keeper") &
          " rev-parse HEAD").strip()

      var coveredTags = 0
      for kind in [rkJunction, rkSymlink]:
        let tag = reparseKindName(kind)
        let workspaceRoot = scratch / ("ws-" & tag)
        createDir(workspaceRoot / "projects")
        createDir(workspaceRoot / "repos")
        createDir(workspaceRoot / ".repro")
        writeFile(workspaceRoot / "precious.txt", "must survive\n")
        createDir(workspaceRoot / "precious-dir")
        writeFile(workspaceRoot / "precious-dir" / "inner.txt", "also\n")

        # `hub` depends on `linked`, so removing `hub` sweeps `linked` into
        # the GC set without anyone naming it — the second route.
        writeFragment(workspaceRoot / "repos" / "hub.toml", "hub", "hub",
          depends = @["linked"])
        writeFragment(workspaceRoot / "repos" / "linked.toml",
          "linked", "linked")
        writeFragment(workspaceRoot / "repos" / "keeper.toml",
          "keeper", "keeper", remote = "keeper-origin")
        writeFile(workspaceRoot / "projects" / "rooted.toml",
          "schema = \"reprobuild.workspace.project.v1\"\n\n" &
          "[project]\nname = \"rooted\"\ndefault_revision = \"main\"\n" &
          "trunk = \"main\"\n\n" &
          "[[remote]]\nname = \"org\"\nfetch = \"" &
            fileUrl(hubOrigin) & "\"\n\n" &
          "[[remote]]\nname = \"keeper-origin\"\nfetch = \"" &
            fileUrl(keeperOrigin) & "\"\n\n" &
          "includes = [\n  \"repos/hub.toml\",\n" &
          "  \"repos/linked.toml\",\n  \"repos/keeper.toml\",\n]\n")
        writeFile(workspaceRoot / ".repro" / "workspace.toml",
          "schema = \"reprobuild.workspace.local.v1\"\n\n" &
          "[workspace]\nproject = \"rooted\"\nbranch = \"main\"\n")

        discard requireGit(gitBin, "clone --quiet " & q(fileUrl(hubOrigin)) &
          " " & q(workspaceRoot / "hub"))
        discard requireGit(gitBin, "clone --quiet " &
          q(fileUrl(keeperOrigin)) & " " & q(workspaceRoot / "keeper"))

        let hostile = workspaceRoot / "linked"
        let made = makeDirReparsePoint(kind, hostile, workspaceRoot)
        if not made.ok:
          checkpoint("reparse tag '" & tag &
            "' is not available on this host: " & made.why)
          continue
        links.add(hostile)
        inc coveredTags
        checkpoint("reparse tag: " & tag)

        # PRE-STATE: the spelling is one the own-tree question accepts.
        check checkoutPathRejection("linked") == ""
        check symlinkExists(hostile)

        let projectFile = workspaceRoot / "projects" / "rooted.toml"
        let projectBefore = readFile(projectFile)

        # ---- route 1: NAMED as the target -------------------------------
        let named = runShell(shellCommand([repro, "remove", "linked",
          "--force", "--workspace-root=" & workspaceRoot]))
        checkpoint("repro remove linked (" & tag & "): " & named.output)
        check named.code == 1
        check named.output.contains("refusing to remove 'linked'")
        check named.output.contains("resolves to the workspace root itself")
        check named.output.contains("Remedy:")
        # Nothing at all was mutated — the project file first, because it is
        # what distinguishes this route from the swept one below.
        check readFile(projectFile) == projectBefore
        check dirExists(workspaceRoot / "hub" / ".git")
        check dirExists(workspaceRoot / "keeper" / ".git")
        check dirExists(workspaceRoot / "projects")
        check dirExists(workspaceRoot / "repos")
        check fileExists(workspaceRoot / "precious.txt")

        # ---- route 2: SWEPT INTO the GC set via `depends` ----------------
        let swept = runShell(shellCommand([repro, "remove", "hub",
          "--force", "--workspace-root=" & workspaceRoot]))
        checkpoint("repro remove hub (" & tag & "): " & swept.output)
        check swept.code == 1
        check swept.output.contains("refusing to remove 'linked'")
        check swept.output.contains("resolves to the workspace root itself")
        # The ordinary checkout in the SAME GC set is gone. Asserted FIRST:
        # without it the run could have "survived" by doing nothing at all,
        # and every assertion below would still pass.
        check not dirExists(workspaceRoot / "hub")
        check dirExists(workspaceRoot / "keeper" / ".git")
        # ...and the workspace root survived both routes.
        check dirExists(workspaceRoot)
        check dirExists(workspaceRoot / "projects")
        check dirExists(workspaceRoot / "repos")
        check fileExists(workspaceRoot / "precious-dir" / "inner.txt")
        check fileExists(workspaceRoot / "precious.txt")
        if fileExists(workspaceRoot / "precious.txt"):
          check readFile(workspaceRoot / "precious.txt") == "must survive\n"

      check coveredTags > 0
      when defined(windows):
        check coveredTags == 2
