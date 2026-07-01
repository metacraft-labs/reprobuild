## Unified-Locking-And-Hooks HL-8 — the user-facing docs reflect the
## shipped behavior: (a) the corrected ``CLI/hooks.md`` no longer over-claims
## that ``pre-receive`` is authoritative for locks GENERALLY, and DOES carry
## the public-tier-only server-gate language; (b) the ``reprobuild/docs/``
## user-guide locking page EXISTS and carries the scheme-selection and
## refusal-recovery sections.
##
## This is a pure documentation-content test: it reads the two doc files from
## disk and asserts on stable phrases / section headers. It builds nothing and
## drives no binary.
##
## Falsifiability (confirmed by the implementer, then reverted):
##   - Restore the stale ``authoritative enforcement is server-side
##     (pre-receive / required check)`` wording to ``CLI/hooks.md`` ⇒
##     assertion (A1) trips.
##   - Delete the public-tier-only server-gate language from ``CLI/hooks.md`` ⇒
##     assertion (A2) trips.
##   - Remove the "Choosing a scheme" or "Recovering from a refused push"
##     section from the user-guide page ⇒ assertions (B*) trip.
##
## The doc files live in sibling repos of this workspace:
##   - ``reprobuild-specs/CLI/hooks.md``  (the spec-doc, sibling repo)
##   - ``reprobuild/docs/user-guide/workspace-locking.md``  (this repo)
## The test resolves both relative to this source file's location so it is
## location-robust; if a doc file is absent the test is SKIPPED (the sibling
## specs repo may not be checked out in every environment), never a false pass.

import std/[os, strutils, unittest]

proc findUp(startDir, rel: string): string =
  ## Walk up from ``startDir`` looking for ``rel`` (a repo-relative path).
  ## Returns "" when not found within a bounded number of ancestors.
  var dir = startDir
  for _ in 0 .. 8:
    let candidate = dir / rel
    if fileExists(candidate):
      return candidate
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  ""

let thisDir = currentSourcePath().parentDir

# ``reprobuild/docs/user-guide/workspace-locking.md`` — this repo. From
# ``tests/integration`` walk up to the repo root, then into docs.
let guidePath = findUp(thisDir, "docs" / "user-guide" / "workspace-locking.md")

# ``reprobuild-specs/CLI/hooks.md`` — sibling repo. From the reprobuild repo
# root, its parent holds the sibling ``reprobuild-specs`` checkout.
let hooksPath = findUp(thisDir, ".." / "reprobuild-specs" / "CLI" / "hooks.md")

suite "HL-8 docs reflect public-tier-only server gate":

  test "CLI/hooks.md corrected: no stale authoritative-for-locks claim; public-tier-only language present":
    if hooksPath.len == 0 or not fileExists(hooksPath):
      skip()
    else:
      let hooks = readFile(hooksPath)

      # (A1) The stale over-claim MUST be gone. The old wording asserted the
      # server-side pre-receive was authoritative for the publication boundary
      # generally ("authoritative enforcement is server-side (`pre-receive` /
      # required check)"). Any surviving "authoritative"/"pre-receive" claim
      # must be tier-scoped, so the specific stale phrasing must be absent.
      check "authoritative enforcement is server-side" notin hooks

      # (A2) The corrected, public-tier-only server-gate boundary MUST be
      # present: pre-receive is authoritative for certificates + the public
      # committed lock only, never the private tiers.
      check ("public-tier committed `repro.lock` only" in hooks) or
            ("public-tier committed lock only" in hooks) or
            ("public-tier" in hooks and "committed `repro.lock`" in hooks)
      check "gates" in hooks and "public tier" in hooks
      # The private tiers are explicitly named as NOT server-visible.
      check ("never for the team, personal, or evidence backends" in hooks) or
            ("the team, personal, and evidence backends are invisible" in hooks)

  test "user-guide workspace-locking.md exists with scheme-selection + refusal-recovery sections":
    check guidePath.len > 0
    check fileExists(guidePath)
    let guide = readFile(guidePath)

    # (B1) Scheme-selection section + all three tiers.
    check "## Choosing a scheme" in guide
    check "Public-only" in guide
    check "team tier" in guide
    check "personal tier" in guide

    # (B2) The tier-isolation guarantee stated in plain terms.
    check "never crosses a visibility boundary" in guide

    # (B3) Personal-tier workflow incl. the fresh-machine restore how-to.
    check "## The personal-tier workflow" in guide
    check "new machine" in guide

    # (B4) Team-tier workflow, both forms.
    check "## The team-tier workflow" in guide
    check "repro-workspace" in guide
    check ("system" in guide and "apply_if" in guide)

    # (B5) Reading config via `repro locking explain`.
    check "repro locking explain" in guide

    # (B6) Refusal-recovery section + the distinct gate outcomes.
    check "## Recovering from a refused push" in guide
    check "lock-backend-unreachable" in guide
    check "locked-integrity-mismatch" in guide
    check "lock_references_private_repo" in guide
    # The personal-tier WARNING (push still succeeds) is called out.
    check ("still succeeds" in guide) or ("warning" in guide.toLowerAscii())

    # (B7) Legacy-manifest migration via adopt-manifest.
    check "repro locking adopt-manifest" in guide

    # (B8) The hook boundary — public tier gated server-side only.
    check "## The hook boundary" in guide
    check "pre-receive" in guide
    check ("public tier only" in guide) or ("gates\n    the public tier only" in guide) or
          ("gates the public tier only" in guide)
