## repro_workspace_manifests/lock_paths.nim
##
## The lock-store path grammar (RA-32): how a repo or project NAME becomes
## exactly ONE path component of ``locks/<project>/<repo>/<sha>.toml``, and
## how it comes back out.
##
## ## Why an encoding and not a join
##
## ``Workspace-Manifests.md`` §"No shared lock index" makes the per-repo
## directory load-bearing: with the shared index dropped, "the latest
## published lock for repo X" IS ``git log -1 -- locks/<project>/<repo>/``.
## That query is only well-defined if ``<repo>`` is a stable subtree — one
## component, at a fixed depth, addressing exactly one repo.
##
## Repo names are not filename-shaped. Upstream forks are named the way the
## forge names them, and this workspace carries twelve with a slash in the
## name (``stripe/sync-engine``, ``0install/0install``, ``microsoft/BuildXL``,
## ``llvm/llvm-project``, ``Textualize/textual``, …). Joining such a name
## straight into the path produced ``locks/codetracer/stripe/sync-engine/…``
## — depth 5 where the format is depth 4 — which:
##
##   * makes ``git log -1 -- locks/codetracer/stripe/`` answer for a subtree
##     that is not a repo (and would also answer for a repo actually NAMED
##     ``stripe``), and
##   * loses the name: a reader taking the second-to-last component reads
##     ``sync-engine``, which is a different repo.
##
## ## The three candidates
##
## 1. **Reject the name.** Simple, but twelve legitimate repos in this
##    workspace could then never participate in team/personal locking at all.
## 2. **Sanitize** (the old ``safeFilenameSegment``: non-alphanumerics collapse
##    to ``-``). Keeps depth 4 but is LOSSY and NOT injective —
##    ``stripe/sync-engine`` and ``stripe-sync-engine`` become the same
##    subtree, so one repo's revision becomes readable as another's — and the
##    name cannot be recovered, so a reader cannot bind a record to its repo.
## 3. **Encode reversibly.** Depth stays 4, the subtree query stays exact, the
##    map name→segment is injective (no two names share a subtree) and
##    invertible (the reader recovers the name from the path).
##
## (3) is the only one that satisfies the spec's own reasoning about the
## subtree query, so that is what this module implements.
##
## ## The grammar
##
## ``[A-Za-z0-9._-]`` pass through; every other byte becomes ``%HH`` with
## UPPERCASE hex. ``%`` itself is therefore always escaped (``%25``), which is
## what makes the encoding prefix-free and the inverse unambiguous. Two
## whole-segment fixups follow, both reversible and both unreachable by the
## per-character pass (``.`` and the ASCII letters are literal, so the
## per-character pass can never emit ``%2E`` or ``%43``):
##
##   * a stem matching a reserved DOS device name (``CON``, ``PRN``, ``AUX``,
##     ``NUL``, ``COM1``-``COM9``, ``LPT1``-``LPT9``, with or without an
##     extension) has its first character escaped — those names cannot be
##     opened as files on Windows;
##   * a TRAILING ``.`` is escaped. Windows silently strips it, and this one
##     rule also settles the two traversal segments: ``.`` encodes to ``%2E``
##     and ``..`` to ``.%2E``, neither of which is a traversal. Ordinary
##     dotted names (``.gitignore``, ``a.b``) are untouched.
##
## Every name that is already filename-shaped — which is every repo in the
## 159 records currently in the workspace's manifest store — encodes to
## itself, so this is not a migration for them.

import std/strutils

const
  lockSegmentLiteralChars* = {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.'}
    ## The bytes that stand for themselves in a lock path component.

  lockRecordExt* = ".toml"

  lockRecordPathDepth* = 4
    ## ``locks`` / ``<project>`` / ``<repo>`` / ``<sha>.toml``. The single
    ## number the writer and every reader agree on.

proc hexEscape(ch: char): string =
  const digits = "0123456789ABCDEF"
  result = newStringOfCap(3)
  result.add('%')
  result.add(digits[(ord(ch) shr 4) and 0xF])
  result.add(digits[ord(ch) and 0xF])

proc hexValue(ch: char): int =
  case ch
  of '0'..'9': ord(ch) - ord('0')
  of 'a'..'f': ord(ch) - ord('a') + 10
  of 'A'..'F': ord(ch) - ord('A') + 10
  else: -1

proc isReservedDeviceStem(segment: string): bool =
  ## Windows refuses to open ``CON``, ``NUL`` & co. as files, with or without
  ## an extension. Matched on the stem, case-insensitively, the way Windows
  ## matches it.
  var stem = segment
  let dot = stem.find('.')
  if dot >= 0: stem = stem[0 ..< dot]
  let upper = stem.toUpperAscii()
  if upper in ["CON", "PRN", "AUX", "NUL"]: return true
  if upper.len == 4 and upper[3] in {'1'..'9'} and
      (upper[0 ..< 3] == "COM" or upper[0 ..< 3] == "LPT"): return true
  false

proc encodeLockPathSegment*(value: string): string =
  ## Encode one repo/project/sha NAME into one lock-path component.
  ## Injective and invertible; see the module header for the grammar.
  ## An empty name encodes to the empty string — callers must reject an
  ## empty name before building a path from it (``isLockPathName``).
  result = newStringOfCap(value.len + 8)
  for ch in value:
    if ch in lockSegmentLiteralChars: result.add(ch)
    else: result.add(hexEscape(ch))
  if result.len == 0: return
  if isReservedDeviceStem(result):
    result = hexEscape(result[0]) & result[1 .. ^1]
  if result[^1] == '.':
    result = result[0 ..< result.high] & hexEscape('.')

proc tryDecodeLockPathSegment*(segment: string; decoded: var string): bool =
  ## Invert ``encodeLockPathSegment``. False when ``segment`` is not a
  ## well-formed component (a stray ``%``, a bad hex pair, or a byte that the
  ## encoder would never have emitted literally — which is how a raw,
  ## unencoded name is detected).
  decoded = newStringOfCap(segment.len)
  var i = 0
  while i < segment.len:
    let ch = segment[i]
    if ch == '%':
      if i + 2 >= segment.len: return false
      let hi = hexValue(segment[i + 1])
      let lo = hexValue(segment[i + 2])
      if hi < 0 or lo < 0: return false
      decoded.add(chr(hi * 16 + lo))
      i += 3
    elif ch in lockSegmentLiteralChars:
      decoded.add(ch)
      inc i
    else:
      return false
  true

proc decodeLockPathSegment*(segment: string): string =
  ## The decoded name, or ``""`` when ``segment`` is not a well-formed
  ## component. ``""`` is unambiguous as a failure signal because an empty
  ## name is never a valid one.
  if not tryDecodeLockPathSegment(segment, result): result = ""

proc isCanonicalLockPathSegment*(segment: string): bool =
  ## True when ``segment`` is EXACTLY what this module would have written for
  ## the name it decodes to. Rejects an empty component, a raw unencoded name
  ## carrying a byte outside the literal set, a non-canonical spelling
  ## (lowercase hex, a gratuitously escaped literal), and the traversal
  ## components ``.`` / ``..``.
  if segment.len == 0: return false
  var decoded: string
  if not tryDecodeLockPathSegment(segment, decoded): return false
  if decoded.len == 0: return false
  encodeLockPathSegment(decoded) == segment

proc isLockPathName*(value: string): bool =
  ## True when ``value`` is usable as a lock-path NAME at all. The encoding
  ## makes any byte sequence safe as a path component, so the only genuinely
  ## unusable name is the empty one (and a NUL, which no filesystem carries).
  value.len > 0 and '\0' notin value

type
  LockRecordPath* = object
    ## The decomposition of a lock record's store-relative path. This is the
    ## ONE decomposer the writer and every reader share; before RA-32 five
    ## call sites open-coded the length check and disagreed about it
    ## (``parts.len < 4`` in one, ``parts.len != 4`` in four), which is why a
    ## bad path was accepted at read time and only refused later, at publish.
    ok*: bool
    relPath*: string          ## input, normalized to forward slashes
    project*: string          ## DECODED project name
    repo*: string             ## DECODED repo name
    sha*: string              ## DECODED filename stem
    projectSegment*: string   ## as it appears on disk
    repoSegment*: string      ## as it appears on disk
    canonicalRelPath*: string ## where this record SHOULD live; "" if unknown
    diagnostic*: string       ## why it is not ``ok`` — actionable, names the
                              ## canonical path when one can be derived

proc lockRecordFileName*(triggerSha: string): string =
  encodeLockPathSegment(triggerSha) & lockRecordExt

proc lockRecordRelPath*(project, repo, sha: string): string =
  ## ``locks/<project>/<repo>/<sha>.toml`` with every component encoded.
  "locks/" & encodeLockPathSegment(project) & "/" &
    encodeLockPathSegment(repo) & "/" & lockRecordFileName(sha)

proc lockRecordSubtreeRelPath*(project, repo: string): string =
  ## The subtree pathspec of ``git log -1 -- locks/<project>/<repo>/``.
  "locks/" & encodeLockPathSegment(project) & "/" &
    encodeLockPathSegment(repo) & "/"

proc parseLockRecordRelPath*(relPath: string): LockRecordPath =
  ## Decompose and VALIDATE a store-relative lock record path.
  result.relPath = relPath.replace('\\', '/')
  let parts = result.relPath.split('/')
  if parts.len == 0 or parts[0] != "locks":
    result.diagnostic = "lock record path is not under locks/: " & relPath
    return
  if parts.len != lockRecordPathDepth:
    # The historical failure: a repo name carrying a slash was joined straight
    # into the path, so the record landed one (or more) levels too deep.
    # Say which record it is and where it belongs — the caller can migrate it.
    if parts.len > lockRecordPathDepth and parts[^1].endsWith(lockRecordExt):
      let projectRaw =
        block:
          var d: string
          if tryDecodeLockPathSegment(parts[1], d) and d.len > 0: d
          else: parts[1]
      let repoRaw = parts[2 .. ^2].join("/")
      let shaRaw =
        block:
          let stem = parts[^1][0 ..< parts[^1].len - lockRecordExt.len]
          var d: string
          if tryDecodeLockPathSegment(stem, d) and d.len > 0: d
          else: stem
      result.canonicalRelPath = lockRecordRelPath(projectRaw, repoRaw, shaRaw)
      result.diagnostic = "lock record path has " & $parts.len &
        " components where the format has " & $lockRecordPathDepth &
        " (the repo name was joined into the path instead of encoded into " &
        "one component): " & relPath & " — the canonical path is " &
        result.canonicalRelPath
    else:
      result.diagnostic = "lock record path has " & $parts.len &
        " components where the format has " & $lockRecordPathDepth & ": " &
        relPath
    return
  if not parts[^1].endsWith(lockRecordExt):
    result.diagnostic = "lock record filename does not end in " &
      lockRecordExt & ": " & relPath
    return
  let stem = parts[^1][0 ..< parts[^1].len - lockRecordExt.len]
  for segment in [parts[1], parts[2], stem]:
    if not isCanonicalLockPathSegment(segment):
      result.diagnostic = "lock record path component '" & segment &
        "' is not a canonical lock path component: " & relPath
      return
  result.projectSegment = parts[1]
  result.repoSegment = parts[2]
  result.project = decodeLockPathSegment(parts[1])
  result.repo = decodeLockPathSegment(parts[2])
  result.sha = decodeLockPathSegment(stem)
  result.canonicalRelPath = result.relPath
  result.ok = true

proc canonicalLockRecordRelPath*(relPath: string): string =
  ## Where the record at ``relPath`` belongs. Equal to ``relPath`` when it is
  ## already canonical; ``""`` when no canonical form can be derived.
  parseLockRecordRelPath(relPath).canonicalRelPath

proc isCanonicalRepoName*(value: string): bool =
  ## A repo NAME may carry a slash (forge-shaped names do), but it is still a
  ## name and not a path: no backslash, no absolute anchor, no empty or
  ## traversal component. Used to bind a record's body to its path.
  if value.len == 0 or '\0' in value or '\\' in value: return false
  if value.startsWith("/") or value.endsWith("/"): return false
  for part in value.split('/'):
    if part.len == 0 or part == "." or part == "..": return false
  true
