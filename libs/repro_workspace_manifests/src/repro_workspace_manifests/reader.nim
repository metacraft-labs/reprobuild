# repro_workspace_manifests/reader.nim
#
# nim-toml-serialization pinned at status-im/nim-toml-serialization
# b5b387e6fb2a7cc75d54a269b07cc6218361bd46 (v0.2.18).
#
# Public `read*` procs for every schema in Workspace-Manifests.md. The
# pattern is identical across schemas:
#
#   1. Slurp the file (turn IO errors into structured diagnostics).
#   2. Run a permissive probe that extracts the top-level `schema` string
#      (with `TomlUnknownFields` set so the probe never trips on the
#      schema's body shape). Compare against the expected version.
#   3. Strict-decode the typed record via `Toml.decode`. Convert any
#      strict-mode parser error into `WorkspaceManifestParseError`, lifting
#      the offending key into `keyPath`.
#   4. Enforce required-key invariants the strict reader cannot enforce on
#      its own (status-im/nim-toml-serialization silently default-initialises
#      missing scalar fields).

import std/[options, os, strutils]
import toml_serialization
import toml_serialization/types as toml_types
import types
import diagnostics

# ---- helpers --------------------------------------------------------------

proc slurpManifest(path, expectedSchema: string): string =
  ## Read the file at `path`. Raise a `WorkspaceManifestParseError` with an
  ## empty `keyPath` / empty `observedSchema` if the file is missing or
  ## unreadable; that empty `observedSchema` is the documented shape for
  ## file-level failures.
  if not fileExists(path):
    raiseManifestError(path, "", expectedSchema, "",
      "manifest file does not exist")
  try:
    result = readFile(path)
  except IOError as e:
    raiseManifestError(path, "", expectedSchema, "", e.msg)
  except OSError as e:
    raiseManifestError(path, "", expectedSchema, "", e.msg)

proc validateSchema(path, content, expectedSchema: string) =
  ## Permissive probe: extracts the top-level `schema` value via
  ## `Toml.decode(..., string, "schema")`, which navigates to just that
  ## key and ignores the rest of the file. Raises
  ## `WorkspaceManifestParseError` on schema-version mismatch, on a missing
  ## `schema` key (observed = ""), or on a probe-level TOML parse failure.
  ##
  ## When the top-level `schema` key itself is missing, the toml-serialization
  ## parser raises `TomlError` with the canonical message
  ## "key not found: 'schema'". The wrapper translates that into a structured
  ## diagnostic with `keyPath = "schema"` and `observedSchema = ""` so the
  ## downstream caller can tell schema-missing apart from schema-mismatch.
  var observed: string
  try:
    observed = Toml.decode(content, string, "schema")
  except TomlError as e:
    let lowered = e.msg.toLowerAscii()
    if "key not found" in lowered and "'schema'" in lowered:
      raiseManifestError(path, "schema", expectedSchema, "",
        "top-level `schema` key is missing")
    raiseManifestError(path, "", expectedSchema, "", e.msg)
  except CatchableError as e:
    raiseManifestError(path, "", expectedSchema, "", e.msg)

  if observed.len == 0:
    raiseManifestError(path, "schema", expectedSchema, "",
      "top-level `schema` key is missing or empty")

  if observed != expectedSchema:
    raiseManifestError(path, "schema", expectedSchema, observed,
      "schema version mismatch")

proc fallbackTomlMessage(): string =
  ## Synthetic diagnostic for the case where status-im/nim-toml-serialization
  ## raises a ``TomlError`` whose ``msg`` is the empty string. The empty-msg
  ## arm is rare on Linux but reproducibly hit on Windows fixtures that
  ## interpolate raw Windows paths into TOML basic strings: ``"C:\Users\..."``
  ## is parsed as the invalid escape ``\U`` (TOML basic strings reserve
  ## ``\u`` / ``\U`` for 4- / 8-hex-digit Unicode escapes). Without the
  ## fallback the wrapped ``WorkspaceManifestParseError`` ends up with an
  ## empty ``innerMessage`` and the diagnostic reads ``schema expected=X
  ## observed=X:`` with no explanation. The fallback names the most likely
  ## culprit so the next failure is actionable rather than opaque.
  "TOML parser raised with no message; common cause: unescaped backslash " &
    "in a basic string (\"...\") — TOML reads \\U / \\u / \\b / \\f / " &
    "\\n / \\r / \\t / \\\" / \\\\ as escape sequences. If the value is a " &
    "filesystem path or file:// URL, escape backslashes (\\\\) or switch to " &
    "forward slashes / TOML literal strings ('...')."

proc decodeStrict[T](path, content, expectedSchema: string;
                     RecordType: typedesc[T]): T =
  ## Strict-mode decode of the typed record. The `TomlUnknownFields` flag is
  ## deliberately NOT set: any unknown top-level key (or unknown key under
  ## one of the declared sub-tables) raises a `TomlError` whose message we
  ## scrape for the offending key path.
  try:
    result = Toml.decode(content, RecordType)
  except TomlError as e:
    let inner = if e.msg.len > 0: e.msg else: fallbackTomlMessage()
    let keyPath = extractStrictModeKeyPath(e.msg)
    raiseManifestError(path, keyPath, expectedSchema, expectedSchema, inner)
  except CatchableError as e:
    let inner = if e.msg.len > 0: e.msg else: fallbackTomlMessage()
    raiseManifestError(path, "", expectedSchema, expectedSchema, inner)

template requireNonEmpty(path, expectedSchema, keyPath, value: untyped) =
  ## status-im/nim-toml-serialization silently fills a missing scalar with
  ## that scalar's zero value. The schema spec marks specific keys
  ## load-bearing; this guard turns "missing required key" into a structured
  ## diagnostic rather than a misleading downstream failure.
  if value.len == 0:
    raiseManifestError(path, keyPath, expectedSchema, expectedSchema,
      "required key `" & keyPath & "` is missing or empty")

# ---- repos/<repo>.toml -----------------------------------------------------

const workspaceRootCheckoutPath* = "."
  ## The one spelling of "this repo IS the workspace root".
  ##
  ## The workspace root repo is a first-class member of the model, not an
  ## absence from it: it is what keys a commit-addressed lock backend
  ## (CLI/develop.md §"Which record, for a commit-addressed backend"), it is
  ## what the develop-manageable set is defined as the union *minus*
  ## (§"Composing the lock set"), and it is the only repo that can carry the
  ## root's own `depends` edges. Reprobuild writes this exact value into the
  ## locks it emits (`LockedDep.path = "."`) and every consumer recognizes it
  ## with a literal `== "."` compare — `isRootLockedDep`, the root-repo lookup
  ## in `composeDevelopLockSet`, the integrity walk, the lock-claim keying.
  ##
  ## Because those compares are EXACT, the spelling is load-bearing rather
  ## than cosmetic: `./.` denotes the same directory but is not `.`, so it
  ## would be read as an ordinary sibling checkout whose target happens to be
  ## the workspace root — the very confusion the guard below exists to
  ## prevent. One meaning, one spelling.

proc pathTraversalRejection*(value: string): string =
  ## Why `value` may not be joined onto a directory this process owns, or ""
  ## when it may.
  ##
  ## The narrowest of the questions in this file, and the only one that is not
  ## about checkout paths specifically: it asks whether the string can steer
  ## the join OUT of the directory it is appended to. Anything used as a path
  ## segment against a location reprobuild creates or deletes owes this — a
  ## declared checkout path, and also a lock-supplied `name` used as a cache
  ## directory (`<producerCacheRoot> / dep.name / <revision>`, which ends in a
  ## `removeDir`).
  ##
  ## Deliberately says nothing about `.` or emptiness: those are *meaningful*
  ## in some planes (the workspace root repo is declared `path = "."`, a lock
  ## records it as `"."` or `""`) and answering them here would force every
  ## caller to take an answer it does not want.
  if isAbsolute(value):
    return "must be relative to the workspace root, not absolute"
  # Windows drive-relative (`C:foo`) is neither absolute nor safely relative:
  # it resolves against that drive's current directory, which is process state
  # this code does not control.
  if value.len >= 2 and value[1] == ':':
    return "must not be drive-relative"
  for raw in value.split({'/', '\\'}):
    if raw.strip() == "..":
      return "must not contain a `..` segment (it would escape the " &
        "workspace root)"
  ""

proc checkoutPathEscapeRejection(value: string): string =
  ## The rules BOTH manifest-plane questions below share: why `value` is not a
  ## plain workspace-relative directory reference at all, or "" when it is one.
  ##
  ## Every consumer turns a declared checkout path into
  ## `<workspaceRoot> / <path>`, so an absolute path, a Windows drive-relative
  ## path, or one containing `..` names a location the workspace does not own.
  ## None of those is ever legitimate in a MANIFEST declaration. (The LOCK
  ## plane answers `..` differently — see `lockedCheckoutPathRejection` — and
  ## that difference is the whole reason these are separate procs.)
  if value.len == 0:
    return "must not be empty"
  let traversal = pathTraversalRejection(value)
  if traversal.len > 0:
    return traversal
  var meaningful = 0
  for raw in value.split({'/', '\\'}):
    if raw.strip().len > 0:
      inc meaningful
  if meaningful == 0:
    return "must name a directory"
  ""

proc resolvesToWorkspaceRoot(value: string): bool =
  ## True when `value` is made only of `.` segments, so
  ## `<workspaceRoot> / <value>` IS the workspace root.
  var meaningful = 0
  for raw in value.split({'/', '\\'}):
    let segment = raw.strip()
    if segment.len > 0 and segment != ".":
      inc meaningful
  meaningful == 0

proc checkoutPathRejection*(value: string): string =
  ## Why `value` is not usable as a directory a consumer may CREATE or DELETE
  ## as a repo's OWN TREE, or "" when it is fine.
  ##
  ## This is the question standing in front of a `removeDir`. Several
  ## consumers legitimately delete the directory they compute — a
  ## half-finished clone is cleaned up by removing its target, a checkout that
  ## dies mid-filter is discarded the same way, disabling a project removes
  ## the trees only it declared — and that is correct exactly as long as the
  ## computed directory is the repo's own tree. Given `.` the identical line
  ## computes the WORKSPACE ROOT and given `../x` a sibling, so a degenerate
  ## value here is not a bad checkout, it is an unbounded delete somewhere
  ## else on the disk, arriving through the recovery paths, which are the ones
  ## nobody exercises by hand.
  ##
  ## Nested paths stay legal — `a/b/c` is a normal declaration, and one repo
  ## checked out underneath another's tree is an existing, supported layout.
  let escape = checkoutPathEscapeRejection(value)
  if escape.len > 0:
    return escape
  if resolvesToWorkspaceRoot(value):
    return "must name a directory beneath the workspace root, not the " &
      "workspace root itself"
  ""

proc declaredCheckoutPathRejection*(value: string): string =
  ## Why `value` is not usable as a DECLARED checkout path in a manifest, or
  ## "" when it is fine. This is the schema boundary, and it is deliberately
  ## NOT the same question as `checkoutPathRejection` above.
  ##
  ## `1c005c6f` made the reader ask the own-tree question, which refused
  ## `path = "."` — and `.` is the one value a workspace uses to declare its
  ## ROOT repo, the only carrier of the root's direct `depends` edges. The
  ## effect was a rule the system broke against itself: reprobuild SYNTHESIZES
  ## `path: "."` into the locks it writes (`committedLockDerivedProject`,
  ## `populateLockedDeps`), `readLock` accepts it, `composeDevelopLockSet`
  ## looks a manifest-resolved repo at `"."` up by name to key commit-
  ## addressed backends, and `repro develop` carries a bespoke diagnostic for
  ## being asked to develop it — while `readRepoFragment` refused to read it.
  ## A value the writer emits and the reader rejects is the defect, so the
  ## reader asks the declaration question and the delete sites keep asking the
  ## own-tree one.
  ##
  ## Moving the question does NOT make it optional, and it is worth being
  ## exact about why, because getting this wrong is how the exemption turns
  ## into an incident. Refusing `.` here was load-bearing for any delete site
  ## that asked nothing of its own — and there was one: `executeRemove`'s
  ## RA-22 GC ran a bare `removeDir(<workspaceRoot> / repo.path)`, so this
  ## reader was the only thing standing between a declared root repo and a
  ## recursive delete of the workspace. Relaxing the boundary without adding
  ## the guard there made `repro remove` destroy the workspace root and exit
  ## 0. The rule is therefore: every consumer that DELETES a computed checkout
  ## path asks for itself, and the manifest plane has four such consumers —
  ##
  ##   * `executeClone`'s half-clone cleanup, via `removeCloneTargetSafely`,
  ##     which proves containment beneath the workspace root independently of
  ##     where the payload came from (and so covers synthesized payloads that
  ##     never passed through this reader at all);
  ##   * `runWorkspaceDisableCommand`, immediately before its own `removeDir`;
  ##   * `executeRemove`, both for the NAMED target (the request is refused)
  ##     and for the root swept into the GC set through a `depends` closure
  ##     (that one delete is skipped);
  ##   * `executeForceReset`, whose `git clean -ffdx` is a recursive delete
  ##     bounded by the target tree — a bound only while that tree is the
  ##     repo's own.
  ##
  ## THE LOCK PLANE IS NOT COVERED BY ANY OF THAT, and an earlier shape of
  ## this comment claimed otherwise. It asserted that `repro develop`'s
  ## placement deletes were safe because "`developCheckoutDir` remaps `.` to a
  ## sibling". There is no `developCheckoutDir`; the proc is
  ## `developAllTargetPath`, its remap keys on the literal string `"."`, and
  ## the lock reader feeding it validated nothing — so a committed
  ## `repro.lock` declaring `path = "./."` produced a develop target equal to
  ## the workspace root and `repro develop --all --reset` deleted it, `.git`
  ## included. That is why the lock plane now has a boundary of its own:
  ## `lockedCheckoutPathRejection` below, asked where lock bytes become
  ## `LockedDep`s. It is a DIFFERENT question again, because the develop
  ## plane's default topology is a SIBLING (`../<name>`), so "beneath the
  ## workspace root" is not its invariant.
  ##
  ## The behavioural delta of this change, stated exactly: `readRepoFragment`
  ## no longer raises for `.`; `./.` and `.//.` still raise but with a
  ## DIFFERENT diagnostic (the "one spelling" message below, not the own-tree
  ## message), because they are refused for being an unrecognized spelling of
  ## the root rather than for naming the root; and every other value is
  ## unchanged in both acceptance and wording.
  if value == workspaceRootCheckoutPath:
    return ""
  let escape = checkoutPathEscapeRejection(value)
  if escape.len > 0:
    return escape
  if resolvesToWorkspaceRoot(value):
    # `./.`, `.//.`, `. / .` — every other spelling that names the workspace
    # root. No consumer's `== "."` compare recognizes any of them, so they
    # would be read as an ordinary sibling repo whose tree happens to BE the
    # workspace root. See `workspaceRootCheckoutPath`.
    return "resolves to the workspace root; the workspace root repo is " &
      "declared as exactly `" & workspaceRootCheckoutPath & "`"
  ""

proc lockedCheckoutPathRejection*(value: string): string =
  ## Why `value` is not usable as a checkout path recorded in a LOCK, or ""
  ## when it is. The lock plane's boundary — the third question, and the one
  ## that was missing.
  ##
  ## ## Why the lock plane cannot reuse the manifest plane's rule
  ##
  ## A manifest checkout path is a directory beneath the workspace root, full
  ## stop. A LOCK-recorded checkout path is not: `repro develop`'s DEFAULT
  ## placement is the sibling topology one level ABOVE the workspace root
  ## (`../<name>`, CLI/develop.md §"Checkout Placement"), and
  ## `developAllTargetPath` honours a lock `path` that already names such a
  ## location — `../sib` is intentional and documented. So "beneath the
  ## workspace root" is not this plane's invariant, and importing
  ## `checkoutPathRejection` here would refuse a supported layout.
  ##
  ## ## What IS invariant on both planes
  ##
  ## Every consumer computes `<workspaceRoot> / <path>`, and several of them
  ## then DELETE it. The property that must hold is therefore not containment
  ## but this: the computed directory must be one the workspace does not
  ## already occupy — the workspace root itself, or an ancestor of it.
  ##
  ## THIS PROC DECIDES THAT LEXICALLY, AND THE SCOPE OF "LEXICALLY" IS THE
  ## WHOLE OF WHAT IT PROMISES. It reads the string, folds `.` away, cancels
  ## each `..` against the segment in front of it, and answers from the
  ## residue. It touches no filesystem, so it is total, cheap and cannot fail
  ## open on an I/O error — and it is BLIND to everything about the value
  ## that is not in the string.
  ##
  ## ITS VERDICT IS NOT THE SAME ON EVERY PLATFORM, which is worth stating
  ## rather than assuming. The folding below is pure string work and does
  ## behave identically everywhere; the `isAbsolute` gate in FRONT of it does
  ## not, because `std/os`' `isAbsolute` is `when doslikeFileSystem`
  ## (`lib/std/private/ospaths2.nim`: `path[0] in {'/', '\\'}` or a drive
  ## letter on Windows, `path[0] == '/'` on POSIX). So one proc body, two
  ## answers, measured on the two spellings where it matters:
  ##
  ##   `\foo`         Windows: REFUSED (absolute)   POSIX: ACCEPTED
  ##   `\\srv\share`  Windows: REFUSED (UNC)        POSIX: ACCEPTED
  ##
  ## That split is correct — a leading `\` names a root on Windows and is an
  ## ordinary filename character on POSIX — but it means "the lock plane
  ## refuses this" is a PER-PLATFORM statement. On POSIX neither value
  ## escapes: the folding below splits on `\` on EVERY platform, so both fold
  ## to ordinary relative residue (`foo`, `srv/share`) beneath the workspace
  ## root, and there is nothing left to refuse.
  ##
  ## Two lexical shapes are what the folding catches:
  ##
  ##   * COLLAPSE TO THE ROOT. `./.`, `./`, `a/..`, `.//.` all normalize to
  ##     the workspace root. `isRootLockedDep` recognizes the root by a
  ##     literal `path == "."` (or empty) compare, so none of these is read as
  ##     the root: they enter the develop set as ordinary dependencies whose
  ##     checkout directory happens to BE the workspace root. `repro develop
  ##     --all --reset` then runs `removeDir` on it. Measured: a workspace
  ##     holding `.git`, `PRECIOUS.txt`, `repro.lock` and `src/` was reduced
  ##     to an empty directory, `.git` included, by one committed lock line.
  ##   * COLLAPSE TO AN ANCESTOR. `..`, `../..`, `../sib/..` normalize to a
  ##     directory that CONTAINS the workspace. A sibling is a peer and is
  ##     fine; the parent is not a peer, it is the thing the workspace lives
  ##     inside, and deleting it takes the workspace with it.
  ##
  ## `../sib` is neither, and stays accepted — that is the constraint this
  ## rule was written around, not an exception carved out of it.
  ##
  ## An earlier shape of this comment said these were "two lexical shapes …
  ## and nothing else does", and a later one said the counter-example was
  ## "one `mklink /J` away". BOTH OVERSTATED IT, and the second one in the
  ## more misleading direction: no junction is needed.
  ##
  ## THE RULE IS A CHECK ON THE SPELLING IN ISOLATION. Look at the signature
  ## — `(value: string)`. It is never handed the workspace root, and in
  ## particular never handed the root's own BASENAME, so a value that
  ## descends back into the root by naming it is outside what this proc can
  ## see. With a workspace root of `…\parent\ws`:
  ##
  ##   lockedCheckoutPathRejection("../ws")  ->  ""  (accepted)
  ##   normalizedPath(absolutePath(root / "../ws"))  ==  the workspace root
  ##
  ## and the same holds for `../ws/.`, `../../parent/ws`, and every other
  ## spelling that goes up and comes back down. The folding cannot decide
  ## these, because deciding them needs a second string this proc does not
  ## have.
  ##
  ## So the claim, stated at the size it actually is: a value this proc
  ## accepts is a well-formed relative path whose OWN SEGMENTS do not fold to
  ## the root or to an ancestor. It is not proven to RESOLVE anywhere in
  ## particular — not when the route back in is spelled out (`../ws`), and
  ## not when a reparse point supplies it (W5-R1 below).
  ##
  ## `../ws` is not a live incident, and WHY it is not is the part that
  ## matters here: `developPlacementRejection` catches it downstream, on
  ## RESOLVED values rather than on the spelling, so
  ## `repro develop --all --reset` exits 1 and deletes nothing. That guard is
  ## one of the five W8 reworked, so the containment for this shape lives
  ## entirely in code this proc does not own — which is the reason to record
  ## it here rather than to file it as harmless.
  ##
  ## ## W5-R1 / W5-R2 — CLOSED at the five consumers (W8, 2026-08-27)
  ##
  ## Both residuals this note used to carry are fixed, and NOT here: this proc
  ## is still a check on the SPELLING IN ISOLATION and still cannot resolve
  ## anything. That is deliberate — a filesystem call inside a pure string
  ## rule makes it fallible, TOCTOU-prone and platform-divergent, and the rule
  ## is asked at a boundary that has no workspace root to resolve against.
  ##
  ## W5-R1 was that `../sib` is accepted by design — a sibling is a peer of
  ## the workspace and the develop plane's documented default placement — so
  ## when `sib` was a DIRECTORY JUNCTION or symlink aimed at the workspace,
  ## the accepted-by-design value resolved to the workspace root and no amount
  ## of string folding could tell. Reproduced on `09324b61`, identically for
  ## both reparse tags:
  ##
  ##   mklink /J …\parent\sib …\parent\workspace
  ##   # repro.lock: deps = [{ …, path = "../sib", … }]
  ##   repro develop --all --reset --workspace-root=…\parent\workspace
  ##   # EXIT=0 — and it REPORTED SUCCESS. The workspace was reduced to
  ##   # `.repro`: `.git`, `PRECIOUS.txt`, `src\` and `repro.lock` were gone.
  ##
  ## W5-R2 was that the same comparisons were byte-wise, so `C:\…\W5CASE\ws`
  ## and `C:\…\w5case\ws` — one directory on a case-insensitive volume —
  ## compared UNEQUAL and downgraded "IS the workspace root" to
  ## "beneath"/"disjoint". Latent rather than live, and what made it latent
  ## was the CALLERS, not the comparison: every one of them took both sides
  ## from one `cwd`, so the two spellings never met.
  ##
  ## THE FIX IS ONE CANONICALIZATION APPLIED AT THE FIVE CONSUMERS THAT
  ## DELETE, which is where the workspace root is actually in hand. Each of
  ## them now asks its own question of the RESOLVED target through
  ## `repro_core/path_identity.nim`'s `fsContainment`:
  ##
  ##   * `containmentInWorkspaceRoot` (`git_actions.nim`), serving
  ##     `removeCloneTargetSafely` and `executeForceReset`;
  ##   * `developPlacementRejection`, `executeRemove` (both routes) and
  ##     `runWorkspaceDisableCommand` (all `repro_cli_support.nim`).
  ##
  ## And the primitive is NOT `expandFilename`. An earlier shape of this note
  ## named it; measured on this host, against the very junction above, it does
  ## not resolve one:
  ##
  ##   expandFilename(…\sib)        -> …\sib          (unchanged)
  ##   expandSymlink(…\sib)         -> …\sib          (also unchanged)
  ##   symlinkExists(…\sib)         -> true           (the reparse point IS
  ##                                                   detectable)
  ##
  ## It is `GetFinalPathNameByHandle` on a handle opened with
  ## `FILE_FLAG_BACKUP_SEMANTICS` and WITHOUT `FILE_FLAG_OPEN_REPARSE_POINT`
  ## (so the open traverses the reparse point) on Windows, and `realpath(3)`
  ## on POSIX. `FILE_NAME_NORMALIZED` returns each component in its ON-DISK
  ## case, which is what answers W5-R2 on Windows without guessing a case rule
  ## or querying a volume property; the `(volume, file id)` / `(st_dev,
  ## st_ino)` identity layer answers it where the canonicalization cannot,
  ## because `realpath` does not case-fold. Resolution FAILURE refuses — a
  ## target whose location cannot be established is a target whose containment
  ## cannot be proven — and the per-failure-mode policy, the TOCTOU window
  ## and the threat-model judgement are stated in full at the top of
  ## `path_identity.nim`.
  ##
  ## The two CANONICAL root spellings pass: `"."` (what reprobuild writes) and
  ## `""` (what a lock that omits the key parses to). Both are what
  ## `isRootLockedDep` matches, so both are correctly excluded from the
  ## develop set by the model rather than by this guard.
  if value.len == 0 or value == workspaceRootCheckoutPath:
    return ""
  # Absolute and drive-relative are wrong here for the same reason they are
  # wrong in a manifest: the path is joined onto the workspace root, and these
  # two spellings discard it. `..` is NOT checked here — on this plane it is
  # only sometimes wrong, and which times is decided below on the RESOLVED
  # shape rather than on the presence of the segment.
  if isAbsolute(value):
    return "must be relative to the workspace root, not absolute — " &
      "regenerate the lock with `repro lock refresh`"
  if value.len >= 2 and value[1] == ':':
    return "must not be drive-relative — regenerate the lock with " &
      "`repro lock refresh`"
  # Lexical normalization: fold `.` away, cancel a `..` against the segment in
  # front of it, and count the `..`s that escape past the workspace root.
  var stack: seq[string]
  var ascents = 0
  for raw in value.split({'/', '\\'}):
    let segment = raw.strip()
    if segment.len == 0 or segment == ".":
      continue
    if segment == "..":
      if stack.len > 0: discard stack.pop()
      else: inc ascents
    else:
      stack.add(segment)
  if stack.len > 0:
    return ""
  if ascents == 0:
    return "resolves to the workspace root; a lock records the workspace " &
      "root repo as exactly `" & workspaceRootCheckoutPath & "`, and every " &
      "consumer recognizes it by that exact spelling — regenerate the lock " &
      "with `repro lock refresh`"
  "resolves to a directory that CONTAINS the workspace root; a locked " &
    "checkout path may name a sibling (`../name`) but never an ancestor — " &
    "regenerate the lock with `repro lock refresh`"

proc readRepoFragment*(path: string): RepoFragment =
  let content = slurpManifest(path, schemaRepoFragmentV1)
  validateSchema(path, content, schemaRepoFragmentV1)
  result = decodeStrict(path, content, schemaRepoFragmentV1, RepoFragment)
  requireNonEmpty(path, schemaRepoFragmentV1, "repo.name", result.repo.name)
  requireNonEmpty(path, schemaRepoFragmentV1, "repo.path", result.repo.path)
  let rejection = declaredCheckoutPathRejection(result.repo.path)
  if rejection.len > 0:
    raiseManifestError(path, "repo.path", schemaRepoFragmentV1,
      schemaRepoFragmentV1,
      "checkout path '" & result.repo.path & "' " & rejection)

# ---- url-prefixes/<name>.toml ----------------------------------------------

proc readUrlPrefix*(path: string): UrlPrefixManifest =
  ## Workspace-Membership-Model.md — a URL prefix shared by many repos,
  ## declared once for the workspace. `url` is a PREFIX in every case: the
  ## former "a fetch base ending in .git is used verbatim" special case is not
  ## carried over, because a field whose meaning depends on the shape of its own
  ## value is a defect waiting for the first input of the other shape.
  let content = slurpManifest(path, schemaUrlPrefixV1)
  validateSchema(path, content, schemaUrlPrefixV1)
  result = decodeStrict(path, content, schemaUrlPrefixV1, UrlPrefixManifest)
  requireNonEmpty(path, schemaUrlPrefixV1, "url-prefix.name",
                  result.`url-prefix`.name)
  requireNonEmpty(path, schemaUrlPrefixV1, "url-prefix.url",
                  result.`url-prefix`.url)

# ---- repo-sets/<set>.toml --------------------------------------------------

proc readRepoSet*(path: string): RepoSetManifest =
  ## A named membership list (`member_sets` + `member_repos`). The strict
  ## decode is what forbids identity fields: `default_revision`, `trunk` and
  ## friends are simply not on `RepoSetManifest`, so a shared set cannot
  ## quietly become a half-project. It is also what rejects the single-list
  ## `members` spelling this replaced — a bare name that had to be resolved
  ## against both namespaces at once, which no manifest can express now.
  let content = slurpManifest(path, schemaRepoSetV1)
  validateSchema(path, content, schemaRepoSetV1)
  result = decodeStrict(path, content, schemaRepoSetV1, RepoSetManifest)
  requireNonEmpty(path, schemaRepoSetV1, "repo-set.name",
                  result.`repo-set`.name)

# ---- templates/<template>.toml ---------------------------------------------

proc readTemplate*(path: string): TemplateManifest =
  ## Workspace-Membership-Model.md §"Templates". The strict decode is what
  ## forbids a template carrying the scaffolded set's name: `TemplateManifest`
  ## has a `[template] name` (the template's own identity) and the two
  ## membership keys, and nothing else — so `[repo-set] name = "…"` in a
  ## template file is an unknown key rather than a silent second source of the
  ## name the `add` argument already gave.
  let content = slurpManifest(path, schemaTemplateV1)
  validateSchema(path, content, schemaTemplateV1)
  result = decodeStrict(path, content, schemaTemplateV1, TemplateManifest)
  requireNonEmpty(path, schemaTemplateV1, "template.name",
                  result.`template`.name)

# ---- projects/<project>.toml ----------------------------------------------

proc readProjectManifest*(path: string): ProjectManifest =
  let content = slurpManifest(path, schemaProjectManifestV1)
  validateSchema(path, content, schemaProjectManifestV1)
  result = decodeStrict(path, content, schemaProjectManifestV1,
                        ProjectManifest)
  requireNonEmpty(path, schemaProjectManifestV1, "project.name",
                  result.project.name)
  for i, r in result.remote:
    if r.name.len == 0:
      raiseManifestError(path, "remote[" & $i & "].name",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "required key `remote[].name` is missing or empty")
    if r.fetch.len == 0:
      raiseManifestError(path, "remote[" & $i & "].fetch",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "required key `remote[].fetch` is missing or empty")

# ---- variants/<...>.toml ---------------------------------------------------

proc readVariantManifest*(path: string): VariantManifest =
  let content = slurpManifest(path, schemaVariantManifestV1)
  validateSchema(path, content, schemaVariantManifestV1)
  result = decodeStrict(path, content, schemaVariantManifestV1,
                        VariantManifest)
  requireNonEmpty(path, schemaVariantManifestV1, "variant.name",
                  result.variant.name)
  requireNonEmpty(path, schemaVariantManifestV1, "variant.base",
                  result.variant.base)
  for i, o in result.`override`:
    if o.fragment.len == 0:
      raiseManifestError(path, "override[" & $i & "].fragment",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "required key `override[].fragment` is missing or empty")

# ---- locks/<project>/<sha>.toml --------------------------------------------

proc readLock*(path: string): Lock =
  let content = slurpManifest(path, schemaLockV1)
  validateSchema(path, content, schemaLockV1)
  result = decodeStrict(path, content, schemaLockV1, Lock)
  requireNonEmpty(path, schemaLockV1, "lock.project", result.lock.project)
  requireNonEmpty(path, schemaLockV1, "lock.created_at", result.lock.created_at)
  for i, r in result.repo:
    if r.name.len == 0:
      raiseManifestError(path, "repo[" & $i & "].name",
        schemaLockV1, schemaLockV1,
        "required key `repo[].name` is missing or empty")
    if r.path.len == 0:
      raiseManifestError(path, "repo[" & $i & "].path",
        schemaLockV1, schemaLockV1,
        "required key `repo[].path` is missing or empty")
    # Same question the repo fragment is asked, and for the same reason: a
    # `reprobuild.workspace.lock.v1` record mirrors a MANIFEST repo, so its
    # checkout is a directory beneath the workspace root and `.` is the root
    # repo declaring itself. Asked here because the record is a machine-
    # written artifact that no human reviews, which is the population a
    # degenerate value actually arrives from. Before this the lock reader
    # validated non-emptiness only, so `./.` — a path the fragment reader
    # refuses — round-tripped through a lock untouched.
    let pathRejection = declaredCheckoutPathRejection(r.path)
    if pathRejection.len > 0:
      raiseManifestError(path, "repo[" & $i & "].path",
        schemaLockV1, schemaLockV1,
        "checkout path '" & r.path & "' " & pathRejection &
        " — regenerate the lock with `repro workspace lock`")
    if r.remote.len == 0:
      raiseManifestError(path, "repo[" & $i & "].remote",
        schemaLockV1, schemaLockV1,
        "required key `repo[].remote` is missing or empty")
    if r.revision.len == 0:
      raiseManifestError(path, "repo[" & $i & "].revision",
        schemaLockV1, schemaLockV1,
        "required key `repo[].revision` is missing or empty")

# ---- locks/<project>/index.toml --------------------------------------------

proc readLockIndex*(path: string): LockIndex =
  let content = slurpManifest(path, schemaLockIndexV1)
  validateSchema(path, content, schemaLockIndexV1)
  result = decodeStrict(path, content, schemaLockIndexV1, LockIndex)
  for i, e in result.entry:
    if e.trigger_repo.len == 0:
      raiseManifestError(path, "entry[" & $i & "].trigger_repo",
        schemaLockIndexV1, schemaLockIndexV1,
        "required key `entry[].trigger_repo` is missing or empty")
    if e.trigger_sha.len == 0:
      raiseManifestError(path, "entry[" & $i & "].trigger_sha",
        schemaLockIndexV1, schemaLockIndexV1,
        "required key `entry[].trigger_sha` is missing or empty")
    if e.lock_file.len == 0:
      raiseManifestError(path, "entry[" & $i & "].lock_file",
        schemaLockIndexV1, schemaLockIndexV1,
        "required key `entry[].lock_file` is missing or empty")
    if e.created_at.len == 0:
      raiseManifestError(path, "entry[" & $i & "].created_at",
        schemaLockIndexV1, schemaLockIndexV1,
        "required key `entry[].created_at` is missing or empty")

# ---- snapshots/<name>.toml -------------------------------------------------

proc readSnapshot*(path: string): Snapshot =
  let content = slurpManifest(path, schemaSnapshotV1)
  validateSchema(path, content, schemaSnapshotV1)
  result = decodeStrict(path, content, schemaSnapshotV1, Snapshot)
  requireNonEmpty(path, schemaSnapshotV1, "snapshot.name", result.snapshot.name)
  requireNonEmpty(path, schemaSnapshotV1, "snapshot.project",
                  result.snapshot.project)
  requireNonEmpty(path, schemaSnapshotV1, "snapshot.created_at",
                  result.snapshot.created_at)
  for i, r in result.repo:
    if r.name.len == 0:
      raiseManifestError(path, "repo[" & $i & "].name",
        schemaSnapshotV1, schemaSnapshotV1,
        "required key `repo[].name` is missing or empty")
    if r.path.len == 0:
      raiseManifestError(path, "repo[" & $i & "].path",
        schemaSnapshotV1, schemaSnapshotV1,
        "required key `repo[].path` is missing or empty")
    if r.remote.len == 0:
      raiseManifestError(path, "repo[" & $i & "].remote",
        schemaSnapshotV1, schemaSnapshotV1,
        "required key `repo[].remote` is missing or empty")
    if r.revision.len == 0:
      raiseManifestError(path, "repo[" & $i & "].revision",
        schemaSnapshotV1, schemaSnapshotV1,
        "required key `repo[].revision` is missing or empty")

# ---- .repro/workspace.toml -------------------------------------------------

proc readWorkspaceLocal*(path: string): WorkspaceLocal =
  let content = slurpManifest(path, schemaWorkspaceLocalV1)
  validateSchema(path, content, schemaWorkspaceLocalV1)
  result = decodeStrict(path, content, schemaWorkspaceLocalV1, WorkspaceLocal)
  requireNonEmpty(path, schemaWorkspaceLocalV1, "workspace.project",
                  result.workspace.project)
  for i, m in result.manifest:
    let hasUrl = m.url.isSome and m.url.get().len > 0
    let hasLocal = m.local_path.isSome and m.local_path.get().len > 0
    if not hasUrl and not hasLocal:
      raiseManifestError(path,
        "manifest[" & $i & "].url|local_path",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "manifest layer needs either `url` or `local_path`")
    if m.visibility.len == 0:
      raiseManifestError(path,
        "manifest[" & $i & "].visibility",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "required key `manifest[].visibility` is missing or empty")

# ---- .repro/develop-overrides.toml -----------------------------------------

proc readDevelopOverrides*(path: string): DevelopOverrides =
  let content = slurpManifest(path, schemaDevelopOverridesV1)
  validateSchema(path, content, schemaDevelopOverridesV1)
  result = decodeStrict(path, content, schemaDevelopOverridesV1,
                        DevelopOverrides)
  for i, o in result.`override`:
    if o.package.len == 0:
      raiseManifestError(path, "override[" & $i & "].package",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "required key `override[].package` is missing or empty")
    if o.local_path.len == 0:
      raiseManifestError(path, "override[" & $i & "].local_path",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "required key `override[].local_path` is missing or empty")
    if o.state.len == 0:
      raiseManifestError(path, "override[" & $i & "].state",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "required key `override[].state` is missing or empty")
    if o.created_at.len == 0:
      raiseManifestError(path, "override[" & $i & "].created_at",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "required key `override[].created_at` is missing or empty")

# ---- <host-repo>/.repro-workspace.toml (RA-8 host bootstrap config) ---------

const
  bootstrapConfigFileName* = ".repro-workspace.toml"
    ## Canonical file name of the committed host bootstrap config.
  bootstrapPrivateConfigFileName* = ".repro-workspace-private.toml"
    ## Sibling file carrying credentialed/SSH manifest URLs.

proc readWorkspaceBootstrapPrivate*(path: string): WorkspaceBootstrapPrivate =
  ## Read the private companion config (`.repro-workspace-private.toml`). The
  ## only load-bearing key is `[manifest] private_url`.
  let content = slurpManifest(path, schemaWorkspaceBootstrapV1)
  validateSchema(path, content, schemaWorkspaceBootstrapV1)
  result = decodeStrict(path, content, schemaWorkspaceBootstrapV1,
                        WorkspaceBootstrapPrivate)
  requireNonEmpty(path, schemaWorkspaceBootstrapV1, "manifest.private_url",
                  result.manifest.private_url)

proc readReprobuildConfig*(path: string): ReprobuildConfig =
  ## HL-1 (Unified-Locking-And-Hooks) — read a `reprobuild.config.v1` layered
  ## configuration file (system layer / user dotfiles / VCS-private dir, or an
  ## `apply_if`-referenced routes file). The file may carry `apply_if` bindings
  ## and/or `[locking]` routes; both are optional, so a file carrying only
  ## `schema = "reprobuild.config.v1"` is a valid (empty) layer.
  ##
  ## Q-A / Q-B (spec §11) — on-disk form: a `schema = "reprobuild.config.v1"`
  ## TOML file. To stay within the pinned toml-serialization (which rejects the
  ## `[[array.of.tables]]` double-bracket form for nested arrays), both the
  ## `apply_if` bindings and the `[locking] route` entries are authored as
  ## INLINE-table arrays (the SAME convention `.repro-workspace.toml`'s
  ## `[locking] route = [{ … }]` already uses), e.g.:
  ##
  ##   schema = "reprobuild.config.v1"
  ##   apply_if = [{ under = "~/work/acme/", config = "team-routes.toml" }]
  ##   [locking]
  ##   route = [{ visibility = "team", backend = "git-checkout",
  ##              path = "manifests-team", repos = ["core"] }]
  let content = slurpManifest(path, schemaReprobuildConfigV1)
  validateSchema(path, content, schemaReprobuildConfigV1)
  result = decodeStrict(path, content, schemaReprobuildConfigV1,
                        ReprobuildConfig)

proc readWorkspaceBootstrap*(path: string): WorkspaceBootstrap =
  ## Read a host bootstrap config (`.repro-workspace.toml`). The only
  ## load-bearing required key is `[manifest] url` — without a manifest URL the
  ## config does not configure anything and the caller must fail loud rather
  ## than fall back to a baked-in org default.
  ##
  ## When a sibling `.repro-workspace-private.toml` exists next to `path` and
  ## the public config did not already set `[manifest] private_url`, the
  ## private companion's `[manifest] private_url` is folded into the returned
  ## record so credentialed URLs never have to live in the committed file.
  let content = slurpManifest(path, schemaWorkspaceBootstrapV1)
  validateSchema(path, content, schemaWorkspaceBootstrapV1)
  result = decodeStrict(path, content, schemaWorkspaceBootstrapV1,
                        WorkspaceBootstrap)
  requireNonEmpty(path, schemaWorkspaceBootstrapV1, "manifest.url",
                  result.manifest.url)

  let privatePath = path.parentDir / bootstrapPrivateConfigFileName
  if (result.manifest.private_url.isNone or
      result.manifest.private_url.get().len == 0) and
      fileExists(privatePath):
    let priv = readWorkspaceBootstrapPrivate(privatePath)
    if priv.manifest.private_url.len > 0:
      result.manifest.private_url = some(priv.manifest.private_url)
