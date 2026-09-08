## The compile-time diagnostics of the canonical ``platforms <expr>`` form.
##
## The redesign (``DSL-Macro-Authoring-Guide.md`` in reprobuild-specs) makes
## the platform vocabulary a set of ``const``s resolved by the compiler rather
## than identifiers a macro reads as text. The whole justification for that is
## what happens when the author gets it WRONG, so this file compiles fixture
## recipes with ``nim c`` and asserts on the message — a test that only checked
## "it fails" would keep passing while the diagnostic rots, and the diagnostic
## is the feature.
##
## Assertions:
##   1. A misspelled platform is an UNDECLARED IDENTIFIER error from the
##      compiler, naming the typo — and Nim's own edit-distance suggestion
##      offers the right spelling. No macro-side whitelist produces this; it
##      is the direct payoff of the entries being real symbols.
##   2. ``platforms[windows]`` (no space) is refused with a message naming the
##      missing space. Nim parses that as array indexing, so without a
##      dedicated check it reaches the body partition as ordinary user code
##      and fails as "undeclared identifier: platforms" a long way from the
##      mistake.
##   3. An empty list is refused: a package that can exist nowhere is never
##      what an author means.
##   4. A repeated coordinate is refused.
##   5. ``x86_64 * aarch64`` — a contradiction — is refused NAMING BOTH SIDES,
##      rather than silently resolving to one of them.
##   6. ``platform("<bogus>")`` — the string escape hatch — is refused naming
##      the token.
##   7. The PMC-1 arm lint (an arm outside the declared set) still fires
##      when the declaration uses the canonical form.
##   8. CONTROL: the canonical form compiles cleanly, so (1)-(7) cannot be
##      passing because the fixture scaffolding is broken.
##   9. CONTROL: the LEGACY ``platforms:`` colon block still compiles. The
##      redesign is additive; recipes in the wild keep working.
##
## (5) and (6) are the regression tests for a hazard found by measurement on
## Nim 2.2.8: an unhandled exception raised while evaluating an expression
## bound to a ``static`` parameter is DROPPED, and the VM resumes at the next
## instruction — the callee runs to completion and its value is accepted.
## (Upstream nim-lang/Nim#22623, open since 2023; the compiler evaluates such
## expressions through ``tryConstExpr``, which disables the error-count abort.
## Not macro-specific and no flag changes it — see
## ``reprobuild-specs/upstream-bugs/nim-static-arg-swallows-raise/``.)
##
## Written the obvious way — with the vocabulary helpers raising ``ValueError``
## on a bad token — both of these fixtures COMPILED CLEANLY and recorded a
## wrong declaration (``platform("totally-bogus-token")`` became ``any-any``,
## i.e. a package silently declared available on every platform). The helpers
## are total functions now, encoding the failure in the value, and stage 2
## turns it into the errors asserted below. Make the helpers raise again and
## (5) and (6) both trip.
##
## Hermetic: fixtures are written under the repository's own ``build/``
## tree — so the repo's ``config.nims`` and ``libs/`` search paths govern the
## fixture compile the same way they govern every other recipe — and removed
## afterwards. Nothing on the host is consulted.

import std/[os, osproc, strutils, tempfiles, unittest]

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
  ## tests/integration/<this>.nim -> tests/integration -> tests -> repo root.

proc recipeSource(body: string): string =
  "import repro_project_dsl\n\npackage platformsFormFixture:\n" & body

proc compileFixture(root, name, source: string):
    tuple[output: string; exitCode: int] =
  let dir = root / name
  createDir(dir)
  let file = dir / (name & ".nim")
  writeFile(file, source)
  # ``workingDir`` is load-bearing: without it the fixture fails on a missing
  # import, which also exits non-zero — so the "expected an error" assertions
  # would pass for entirely the wrong reason. The message assertions are the
  # second line of defence, and the two CONTROL cases are the third.
  execCmdEx("nim c --hints:off --warnings:off --compileOnly" &
    " --nimcache:" & quoteShell(dir / "nimcache") &
    " " & quoteShell(file),
    workingDir = RepoRoot)

suite "the platforms form's compile-time diagnostics":

  test "t_platforms_form_diagnostics":
    let scratchParent = RepoRoot / "build" / "test-tmp"
    createDir(scratchParent)
    let scratch = createTempDir("repro-platforms-form-", "", scratchParent)
    defer: removeDir(scratch)

    # ---- (8) CONTROL first: the canonical form compiles ------------------
    # Ordered first deliberately. If this fails, every assertion below is
    # meaningless and the checkpoint says why.
    block canonicalCompiles:
      let (output, exitCode) = compileFixture(scratch, "canonical",
        recipeSource("  ## the reason\n  platforms [windows]\n"))
      if exitCode != 0:
        checkpoint "the canonical form does not compile: " & output
      check exitCode == 0

    # ---- (9) CONTROL: the legacy colon block still compiles --------------
    block legacyCompiles:
      let (output, exitCode) = compileFixture(scratch, "legacy",
        recipeSource("  platforms:\n    [windows]\n" &
          "    msg = \"still supported\"\n"))
      if exitCode != 0:
        checkpoint "the legacy form regressed: " & output
      check exitCode == 0

    # ---- (1) a typo is the COMPILER's undeclared-identifier error --------
    block typoIsUndeclaredIdentifier:
      let (output, exitCode) = compileFixture(scratch, "typo",
        recipeSource("  platforms [windwos]\n"))
      check exitCode != 0
      check output.contains("undeclared identifier: 'windwos'")
      # Nim's own suggestion. A macro-side whitelist could have named the
      # valid tokens, but nothing it emitted would rank them by edit
      # distance to what the author actually typed.
      check output.contains("'windows'")

    # ---- (2) the missing space names itself ------------------------------
    block missingSpace:
      let (output, exitCode) = compileFixture(scratch, "nospace",
        recipeSource("  platforms[windows]\n"))
      check exitCode != 0
      check output.contains("missing a space")
      check output.contains("array indexing")
      # The message must show the corrected line, not just describe it.
      check output.contains("platforms [windows]")

    # ---- (3) an empty declaration ----------------------------------------
    block emptyList:
      let (output, exitCode) = compileFixture(scratch, "empty",
        recipeSource("  platforms []\n"))
      check exitCode != 0
      check output.contains("must name at least one platform")
      # It has to say what to do instead, not just refuse.
      check output.contains("delete the declaration")

    # ---- (4) a repeated coordinate ---------------------------------------
    block duplicate:
      let (output, exitCode) = compileFixture(scratch, "dup",
        recipeSource("  platforms [windows, windows]\n"))
      check exitCode != 0
      check output.contains("'windows' is named twice")

    # ---- (5) a contradiction names BOTH sides ----------------------------
    block contradiction:
      let (output, exitCode) = compileFixture(scratch, "conflict",
        recipeSource("  platforms [x86_64 * aarch64]\n"))
      if exitCode == 0:
        checkpoint "a contradictory constraint compiled clean — the failure " &
          "was dropped and a declaration the author did not write was " &
          "recorded"
      check exitCode != 0
      check output.contains("narrows to both 'x86_64' and 'aarch64'")
      check output.contains("write two entries")

    # ---- (6) the string escape hatch validates ---------------------------
    block unknownToken:
      let (output, exitCode) = compileFixture(scratch, "unknowntoken",
        recipeSource("  platforms [platform(\"totally-bogus-token\")]\n"))
      if exitCode == 0:
        checkpoint "an unrecognised platform token compiled clean — this " &
          "is the any/any silent-availability failure"
      check exitCode != 0
      check output.contains("unknown platform token 'totally-bogus-token'")
      # And it points at the axis vocabulary rather than leaving the author
      # to find it.
      check output.contains("x86_64-windows")

    # ---- (7) the PMC-1 arm lint still fires under the new form -----------
    # ``lintArmsAgainstDeclaredPlatforms`` reads ``pkg.declaredPlatforms``,
    # which both forms populate — but "should still work" is exactly the kind
    # of claim that is true right up until the staging drops a field. The
    # legacy-form version of this lint is pinned by
    # ``t_arm_outside_declared_platforms_is_a_lint_error``; this pins that the
    # canonical form feeds it the same facts.
    block armLintUnderCanonicalForm:
      let (output, exitCode) = compileFixture(scratch, "armlint",
        recipeSource("  platforms [windows]\n" &
          "  provisioning:\n" &
          "    tarball url = \"https://example.invalid/t-1.0.tar.gz\",\n" &
          "      sha256 = \"" & repeat('0', 64) & "\",\n" &
          "      archiveType = \"tar.gz\",\n" &
          "      executablePath = \"bin/t\",\n" &
          "      packageId = \"t@1.0\",\n" &
          "      cpu = \"x86_64\",\n" &
          "      os = \"linux\",\n" &
          "      lockIdentity = \"tarball:t@1.0\"\n"))
      check exitCode != 0
      check output.contains("platformsFormFixture")
      check output.contains("os = \"linux\"")
      check output.contains("outside it")
