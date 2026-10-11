## Content identifiers for test certificates: computing them, validating
## them, and refusing where there is none.
##
## Implements the test-certificate standard's ``Content-Id.md``: the
## self-describing id a certificate carries in ``[certificate.vcs] content``,
## binding it to the CONTENT of the tracked files rather than to a commit. A
## producer and a verifier that compute an id differently never disagree
## loudly; they simply find that nothing matches. That is why this module is
## the one place reprobuild computes a content id, and why it deliberately
## knows nothing about certificate records: the producer, the verifier, the
## pre-commit gate, the push gateway and the CI plan all call the same recipe.
##
## What is here
## ------------
## * ``parseContentId`` classifies an id (§1) as well-formed in a §4
##   algorithm, well-formed in an algorithm outside §4 (NOT malformed: it is
##   an algorithm this implementation cannot compute), or malformed. Nothing
##   is repaired: no lowercasing, no abbreviated matching, no assumed
##   algorithm.
## * ``computeContentId`` computes ``git-tree-sha1`` / ``git-tree-sha256``
##   (§4.1) or ``manifest-v1-sha256`` (§4.2) for the three states of §5 (a
##   working tree, the index being committed, a commit), whole-repository or
##   scoped.
## * ``probeNoContentId`` finds the §3 states that have no honest id, each
##   with its paths and a remedy. ``computeContentId`` runs it and returns the
##   findings instead of an id.
## * ``manifestV1Sha256`` and ``gitTreeIdOfEntries`` compute ids from an
##   explicit entry list, without a repository: the first for any VCS, the
##   second for checking a git tree id independently of git.
## * ``evaluateClaimedContentId`` puts the three together for a verifier:
##   matches, differs, malformed, or cannot-compute (which a caller reports as
##   unverifiable, never as a mismatch).
##
## What computing an id writes
## ---------------------------
## Blob and tree objects in the repository's object store, and nothing else in
## the repository: no ref, no index, no working-tree file, no
## ``sharedindex.*`` file. The user's index is copied into a private
## temporary directory outside the repository, and every index operation runs
## against the copy (§4.1: "the user's staging area is neither read as the
## tested state nor modified"). The directory is removed on every path out.
##
## How it runs git
## ---------------
## As an explicit, visible host tool (``uncontrolledStartProcess``): the
## binary is whatever ``ContentIdGit.binary`` names, which callers that hold
## a resolved git identity pass through. stdout and stderr are captured
## SEPARATELY, because an object id parsed out of a stream with a warning
## interleaved would be wrong rather than noisy, and into files rather than
## pipes, so a command that prints a warning per file cannot deadlock against
## a reader draining the other stream.

import std/[algorithm, os, osproc, sequtils, strtabs, strutils, tables,
            tempfiles, times]

import nimcrypto/[hash, sha, sha2]

import repro_core/ambient_execution

when defined(windows):
  import std/[streams, winlean]

# ---------------------------------------------------------------------------
# Form (Content-Id §1)
# ---------------------------------------------------------------------------

type
  ContentAlgorithm* = enum
    ## The algorithms Content-Id §4 defines. The string value is the
    ## identifier as it appears before the ``:``, compared by exact string
    ## equality.
    caGitTreeSha1 = "git-tree-sha1"
    caGitTreeSha256 = "git-tree-sha256"
    caManifestV1Sha256 = "manifest-v1-sha256"

  ContentIdForm* = enum
    cifWellFormed
      ## A §4 algorithm and a lowercase hex digest of exactly its length.
    cifUnknownAlgorithm
      ## Syntactically sound, in an algorithm §4 does not define. Not
      ## malformed: only the algorithm defines the digest length, and a later
      ## revision of the standard may define it. A verifier treats it as an
      ## algorithm it cannot compute (§5).
    cifMalformed
      ## Decidably invalid.

  ParsedContentId* = object
    form*: ContentIdForm
    text*: string
      ## The input, verbatim.
    algorithmName*: string
      ## Everything before the FIRST ``:``; empty when there is none.
    digest*: string
      ## Everything after the first ``:``.
    algorithm*: ContentAlgorithm
      ## Meaningful only when ``form == cifWellFormed``.
    problem*: string
      ## Why the id is malformed; empty otherwise.

const
  ContentDigestLength*: array[ContentAlgorithm, int] = [40, 64, 64]
    ## The digest length, in hex digits, each §4 algorithm defines.

proc lookupContentAlgorithm*(name: string):
    tuple[known: bool; algorithm: ContentAlgorithm] =
  ## The §4 algorithm ``name`` identifies, by exact string equality, so
  ## ``Git-Tree-SHA1`` is an unknown algorithm, not ``git-tree-sha1``.
  for algorithm in ContentAlgorithm:
    if $algorithm == name:
      return (true, algorithm)
  (false, caGitTreeSha1)

proc isLowerHex(text: string): bool =
  for ch in text:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc parseContentId*(text: string): ParsedContentId =
  ## Classify ``text`` per Content-Id §1. The id splits at the FIRST ``:``,
  ## so ``git-tree-sha1:sha1:<hex>`` has the digest ``sha1:<hex>``, which is
  ## not hex: malformed, not an unknown algorithm.
  result = ParsedContentId(text: text)
  let colon = text.find(':')
  if colon < 0:
    result.form = cifMalformed
    result.problem = "it has no `:` separating the algorithm from the digest"
    return
  result.algorithmName = text[0 ..< colon]
  result.digest = text[colon + 1 .. ^1]
  if result.algorithmName.len == 0:
    result.form = cifMalformed
    result.problem = "nothing precedes the `:`, so it names no algorithm"
    return
  if result.digest.len == 0:
    result.form = cifMalformed
    result.problem = "the digest after the `:` is empty"
    return
  if not result.digest.isLowerHex():
    result.form = cifMalformed
    result.problem =
      if result.digest.toLowerAscii().isLowerHex():
        "the digest contains uppercase hex digits; a digest is lowercase " &
          "and is never lowercased on a reader's behalf"
      else:
        "the digest contains characters other than `0`-`9` and `a`-`f`"
    return
  let (known, algorithm) = lookupContentAlgorithm(result.algorithmName)
  if not known:
    # Its digest length cannot be judged: only the algorithm defines it.
    result.form = cifUnknownAlgorithm
    return
  result.algorithm = algorithm
  if result.digest.len != ContentDigestLength[algorithm]:
    result.form = cifMalformed
    result.problem =
      "a " & $algorithm & " digest has exactly " &
      $ContentDigestLength[algorithm] & " hex digits and this one has " &
      $result.digest.len & " (an abbreviated digest is not matched as a prefix)"
    return
  result.form = cifWellFormed

proc formatContentId*(algorithm: ContentAlgorithm; digest: string): string =
  ## ``<algorithm>:<digest>``.
  $algorithm & ":" & digest

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

type
  NoContentIdReason* = enum
    ## The Content-Id §3 states that have no honest content id. A producer
    ## must not issue a certificate in any of them.
    ncrUnmergedEntries = "the index has unmerged entries"
    ncrAssumeUnchanged = "entries are marked assume-unchanged"
    ncrSkipWorktreePresent =
      "entries are marked skip-worktree while their file is present"
    ncrNestedRepositoryModified = "a nested repository has modified content"
    ncrUnrepresentablePath = "a path cannot be represented"

  NoContentIdFinding* = object
    reason*: NoContentIdReason
    paths*: seq[string]
      ## The repository paths in this state, sorted and deduplicated.

  ContentIdOutcome* = enum
    cioComputed
      ## ``id`` holds the content id.
    cioNoContentId
      ## A §3 state: ``findings`` names each one, with its paths.
    cioCannotCompute
      ## The algorithm cannot be computed for this state, such as
      ## ``git-tree-sha256`` in a SHA-1 repository or an algorithm this
      ## implementation does not know. A verifier reports that as
      ## unverifiable, never as a mismatch (§5).
    cioFailed
      ## The computation itself failed: not a repository, an unknown
      ## revision, an invalid scope, git exiting non-zero. Never an id.

  ContentIdResult* = object
    outcome*: ContentIdOutcome
    id*: string
      ## The full self-describing id; empty unless ``cioComputed``.
    algorithmName*: string
      ## The algorithm asked for, as its identifier.
    digest*: string
      ## The part of ``id`` after the ``:``.
    findings*: seq[NoContentIdFinding]
      ## Every §3 state found, when ``cioNoContentId``.
    reason*: string
      ## Empty when computed; otherwise what prevented an id.

proc remedy*(reason: NoContentIdReason): string =
  ## What the operator does to leave the state, in one sentence.
  case reason
  of ncrUnmergedEntries:
    "resolve the conflicts and stage the results (`git add <path>`), or " &
      "abort the merge"
  of ncrAssumeUnchanged:
    "clear the flag with `git update-index --no-assume-unchanged -- <path>`, " &
      "so git reads the file again"
  of ncrSkipWorktreePresent:
    "clear the flag with `git update-index --no-skip-worktree -- <path>`, or " &
      "remove the file (`git sparse-checkout reapply` does so for a sparse " &
      "checkout)"
  of ncrNestedRepositoryModified:
    "commit or discard the changes inside the nested repository, so its " &
      "checked-out revision describes what is there"
  of ncrUnrepresentablePath:
    "rename the file: a manifest-v1 record cannot hold a path containing NUL"

proc remedy*(finding: NoContentIdFinding): string = remedy(finding.reason)

proc computed(algorithm: ContentAlgorithm; digest: string): ContentIdResult =
  ContentIdResult(outcome: cioComputed, algorithmName: $algorithm,
                  digest: digest, id: formatContentId(algorithm, digest))

proc failed(algorithmName, reason: string): ContentIdResult =
  ContentIdResult(outcome: cioFailed, algorithmName: algorithmName,
                  reason: reason)

proc cannotCompute(algorithmName, reason: string): ContentIdResult =
  ContentIdResult(outcome: cioCannotCompute, algorithmName: algorithmName,
                  reason: reason)

proc describe*(findings: openArray[NoContentIdFinding]): string =
  ## One line per finding: the reason, its paths, and the remedy.
  var lines: seq[string]
  for finding in findings:
    lines.add $finding.reason & " (" & finding.paths.join(", ") & "): " &
      finding.remedy()
  lines.join("\n")

proc noContentId(algorithmName: string;
                 findings: seq[NoContentIdFinding]): ContentIdResult =
  ContentIdResult(outcome: cioNoContentId, algorithmName: algorithmName,
                  findings: findings,
                  reason: "this state has no honest content id:\n" &
                    describe(findings))

proc sortedUnique(paths: seq[string]): seq[string] =
  result = paths
  result.sort(system.cmp[string])
  result = result.deduplicate(isSorted = true)

# ---------------------------------------------------------------------------
# Scopes
# ---------------------------------------------------------------------------

proc scopePathProblem*(path: string): string =
  ## Why ``path`` is not a valid scope path, or "" when it is. A scope path
  ## is repo-relative and ``/``-separated, and is rejected rather than tidied
  ## for the reason an id is never repaired: a scope means exactly what it
  ## says, or nothing.
  if path.len == 0:
    return "a scope path is empty"
  if '\0' in path:
    return "a scope path contains NUL"
  if path.startsWith("/"):
    return "scope path `" & path & "` begins with `/`; scope paths are " &
      "repo-relative"
  if path.endsWith("/"):
    return "scope path `" & path & "` ends with `/`"
  for component in path.split('/'):
    if component.len == 0 or component == "." or component == "..":
      return "scope path `" & path & "` has an empty, `.` or `..` component"
  ""

proc inScope*(path: string; scope: openArray[string]): bool =
  ## Whether repository path ``path`` lies within ``scope`` (empty: the whole
  ## repository). A scope path names that file or the subtree beneath it, by
  ## whole components: ``src/d`` does not contain ``src/db/a.c``.
  if scope.len == 0:
    return true
  for prefix in scope:
    if path == prefix or (path.len > prefix.len and path.startsWith(prefix) and
                          path[prefix.len] == '/'):
      return true
  false

# ---------------------------------------------------------------------------
# Entry lists: manifest-v1-sha256 (§4.2) and git trees without git
# ---------------------------------------------------------------------------

type
  ContentEntry* = object
    ## One tracked path, as Content-Id §4.2 defines an entry.
    path*: string
      ## Repo-relative, ``/``-separated, the byte sequence the VCS records.
    mode*: string
      ## ``100644``, ``100755``, ``120000`` or ``160000``.
    content*: string
      ## The file's bytes, a symlink's target, or for ``160000`` the nested
      ## repository's revision id in ASCII.

const EntryModes = ["100644", "100755", "120000", "160000"]

proc byteOrder(a, b: string): int =
  ## Unsigned comparison of raw bytes, the order §4.2 requires: ``a.b``
  ## (``2E``) before ``a/b`` (``2F``) before ``a0``.
  for i in 0 ..< min(a.len, b.len):
    let x = uint8(a[i])
    let y = uint8(b[i])
    if x != y:
      return (if x < y: -1 else: 1)
  cmp(a.len, b.len)

proc lowerHex(bytes: openArray[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add toHex(int(b), 2).toLowerAscii()

proc sha256Hex*(data: string): string =
  ## Lowercase hex SHA-256 of ``data``'s bytes.
  lowerHex(sha256.digest(data).data)

proc selectEntries(entries: openArray[ContentEntry]; scope: openArray[string];
                   algorithmName: string):
    tuple[selected: seq[ContentEntry]; problem: ContentIdResult; ok: bool] =
  ## The in-scope entries in byte order, after the checks every entry-list
  ## algorithm shares. A path containing NUL is a §3 state (reported as
  ## such); every other defect is a malformed list.
  for prefix in scope:
    let problem = scopePathProblem(prefix)
    if problem.len > 0:
      return (@[], failed(algorithmName, problem), false)
  var unrepresentable: seq[string]
  for entry in entries:
    if '\0' in entry.path:
      if inScope(entry.path, scope):
        unrepresentable.add entry.path.replace("\0", "\\0")
      continue
    if entry.mode notin EntryModes:
      return (@[], failed(algorithmName, "entry `" & entry.path &
        "` has mode `" & entry.mode & "`, which is not one of " &
        EntryModes.join(", ")), false)
    let problem = scopePathProblem(entry.path)
    if problem.len > 0:
      return (@[], failed(algorithmName, "entry path is not a repository " &
        "path: " & problem), false)
    if inScope(entry.path, scope):
      result.selected.add entry
  if unrepresentable.len > 0:
    return (@[], noContentId(algorithmName, @[NoContentIdFinding(
      reason: ncrUnrepresentablePath, paths: sortedUnique(unrepresentable))]),
      false)
  result.selected.sort(proc(a, b: ContentEntry): int = byteOrder(a.path, b.path))
  for i in 1 ..< result.selected.len:
    if result.selected[i - 1].path == result.selected[i].path:
      return (@[], failed(algorithmName, "entry path `" &
        result.selected[i].path & "` is listed twice"), false)
  result.ok = true

proc manifestV1Sha256*(entries: openArray[ContentEntry];
                       scope: openArray[string] = []): ContentIdResult =
  ## ``manifest-v1-sha256`` over ``entries`` (in any order), restricted to
  ## ``scope``. Each in-scope entry is the record
  ## ``<mode> SP <hex sha256(content)> SP <path> NUL``; records are
  ## concatenated in byte order of the full path. An empty scope hashes the
  ## empty string.
  let selection = selectEntries(entries, scope, $caManifestV1Sha256)
  if not selection.ok:
    return selection.problem
  var records = ""
  for entry in selection.selected:
    records.add entry.mode & ' ' & sha256Hex(entry.content) & ' ' &
      entry.path & '\0'
  computed(caManifestV1Sha256, sha256Hex(records))

proc objectDigest(algorithm: ContentAlgorithm; kind, body: string): seq[byte] =
  ## The id of a git object: the hash of ``<kind> SP <length> NUL <body>``.
  let framed = kind & " " & $body.len & "\0" & body
  case algorithm
  of caGitTreeSha1: @(sha1.digest(framed).data)
  of caGitTreeSha256: @(sha256.digest(framed).data)
  of caManifestV1Sha256: raiseAssert "not a git object format"

type
  TreeNode = ref object
    children: Table[string, TreeNode]   # subdirectories
    leaves: Table[string, ContentEntry] # files, links, gitlinks

proc gitTreeOrder(a, b: tuple[name: string; isTree: bool]): int =
  ## git sorts a subtree within its parent as if its name ended in ``/``.
  byteOrder(if a.isTree: a.name & "/" else: a.name,
            if b.isTree: b.name & "/" else: b.name)

proc hexBytes(hex: string): seq[byte] =
  for i in countup(0, hex.len - 1, 2):
    result.add byte(parseHexInt(hex[i .. i + 1]))

proc writeTree(node: TreeNode; algorithm: ContentAlgorithm): seq[byte] =
  var names: seq[tuple[name: string; isTree: bool]]
  for name in node.children.keys: names.add (name, true)
  for name in node.leaves.keys: names.add (name, false)
  names.sort(gitTreeOrder)
  var body = ""
  for (name, isTree) in names:
    var mode: string
    var id: seq[byte]
    if isTree:
      mode = "40000"
      id = writeTree(node.children[name], algorithm)
    else:
      let entry = node.leaves[name]
      mode = entry.mode
      id =
        if entry.mode == "160000": hexBytes(entry.content)
        else: objectDigest(algorithm, "blob", entry.content)
    body.add mode & " " & name & "\0"
    for b in id: body.add char(b)
  objectDigest(algorithm, "tree", body)

proc gitTreeIdOfEntries*(entries: openArray[ContentEntry];
                         algorithm: ContentAlgorithm;
                         scope: openArray[string] = []): ContentIdResult =
  ## The ``git-tree-*`` id of the tree a commit holding exactly ``entries``
  ## (restricted to ``scope``, at their full paths) would record, computed
  ## without git: blob and tree objects are hashed directly. This is an
  ## independent derivation, for checking ids that git produced.
  if algorithm == caManifestV1Sha256:
    return failed($algorithm, "manifest-v1-sha256 is not a git tree id; " &
      "use manifestV1Sha256")
  let selection = selectEntries(entries, scope, $algorithm)
  if not selection.ok:
    return selection.problem
  let root = TreeNode()
  for entry in selection.selected:
    if entry.mode == "160000" and
       (entry.content.len != ContentDigestLength[algorithm] or
        not entry.content.isLowerHex()):
      return failed($algorithm, "nested repository `" & entry.path &
        "` names revision `" & entry.content & "`, which is not a full " &
        $algorithm & " object id")
    let components = entry.path.split('/')
    var node = root
    for component in components[0 ..< ^1]:
      if component in node.leaves:
        return failed($algorithm, "`" & entry.path & "` lies beneath the " &
          "file `" & component & "`")
      node = node.children.mgetOrPut(component, TreeNode())
    if components[^1] in node.children:
      return failed($algorithm, "`" & entry.path & "` is both a file and " &
        "a directory")
    node.leaves[components[^1]] = entry
  computed(algorithm, lowerHex(writeTree(root, algorithm)))

# ---------------------------------------------------------------------------
# Running git
# ---------------------------------------------------------------------------

type
  ContentIdGit* = object
    ## The git a computation runs. ``binary`` is a path, or a bare name the
    ## search path resolves.
    binary*: string

  GitReply = object
    launched: bool
    exitCode: int
    stdout: string
    stderr: string

  Session = object
    git: ContentIdGit
    scratch: string
      ## Private directory outside the repository: temporary indexes and the
      ## captured streams of each command.
    counter: int

proc defaultContentIdGit*(): ContentIdGit = ContentIdGit(binary: "git")

const
  CommandEnvironment = [
    # Scoped paths are passed with `--literal-pathspecs` (§4.1: "Pathspecs
    # MUST be literal"). These keep an inherited setting from fighting that
    # flag or making matching case-insensitive.
    ("GIT_GLOB_PATHSPECS", "0"),
    ("GIT_NOGLOB_PATHSPECS", "0"),
    ("GIT_ICASE_PATHSPECS", "0"),
    # Read-only commands such as `git status` opportunistically rewrite the
    # index they read. They only ever read a temporary copy here, but no
    # optional write is wanted anywhere in this recipe.
    ("GIT_OPTIONAL_LOCKS", "0")]

  CommandConfiguration = [
    # A filesystem monitor lets git skip examining entries it last reported
    # unchanged, so a change the monitor has not delivered yet would be
    # missed. With it off, git drops the "valid" marks it reads from the
    # copied index (§4.1).
    "core.fsmonitor=false",
    # Under `core.splitIndex` a write to a temporary index would also write a
    # `sharedindex.*` file into the repository's git directory, and expire old
    # ones there. A temporary index is always written whole instead.
    "core.splitIndex=false",
    # In a sparse checkout git silently clears the skip-worktree mark of an
    # entry whose file is present when it reads the index, so the probe would
    # see an ordinary entry; yet under a sparse index `add --update` still
    # leaves that file out, and the id would name the indexed bytes while the
    # tests read the present ones. Keeping the mark as recorded lets the probe
    # refuse that state (§3) instead.
    "sparse.expectFilesOutsideOfPatterns=true"]

  StatDistrustTime* = 1'i64
    ## The modification time, in seconds since the epoch, given to the
    ## temporary index before ``git add --update`` runs in it (§4.1).
    ##
    ## ``add --update`` skips reading a file whose stat data matches its index
    ## entry, unless the entry is "racily clean": not older than the INDEX
    ## FILE's own mtime. A fresh copy of the user's index has a fresh mtime,
    ## so a same-size edit made in the second the real index was last written
    ## (which git, reading the real index, would re-read) reads as clean in the
    ## copy, and the id names the old content. Preserving the original's mtime
    ## still misses a rewrite that kept size, mtime and inode where ctime is
    ## not compared. Dated one second after the epoch, every entry is racily
    ## clean and git compares every tracked file's content with its blob. ``0``
    ## would not do: git reads an index timestamp of zero as "unknown" and then
    ## treats no entry as racy.

proc commandEnvironment(overrides: openArray[(string, string)]): StringTableRef =
  result = newStringTable(
    when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  for (key, value) in CommandEnvironment:
    result[key] = value
  for (key, value) in overrides:
    result[key] = value

proc nextScratchPath(session: var Session; stem: string): string =
  inc session.counter
  session.scratch / (stem & "-" & $session.counter)

proc readAndRemove(path: string): string =
  if fileExists(path):
    result = readFile(path)
    removeFile(path)

when defined(windows):
  proc drainProcess(process: Process; input: string): GitReply =
    ## Feed ``input`` and collect both streams until the child exits. The
    ## pipes are drained together with ``PeekNamedPipe``: reading one to its
    ## end first deadlocks once the other fills, and a blocking read stops at
    ## the first short read on this platform.
    let stdinStream = process.inputStream
    if input.len > 0:
      stdinStream.write(input)
    stdinStream.close()
    let handles = [Handle(process.outputHandle), Handle(process.errorHandle)]
    var sinks: array[2, string]
    var buffer {.noinit.}: array[16384, char]
    while true:
      var moved = false
      for i in 0 .. 1:
        var available: int32 = 0
        if peekNamedPipe(handles[i], lpTotalBytesAvail = addr available) and
           available > 0:
          var count: int32 = 0
          let wanted = min(int(available), buffer.len).int32
          if winlean.readFile(handles[i], addr buffer[0], wanted, addr count,
                              nil) != 0 and count > 0:
            let start = sinks[i].len
            sinks[i].setLen(start + count)
            copyMem(addr sinks[i][start], addr buffer[0], count)
            moved = true
      if moved: continue
      let code = process.peekExitCode()
      if code != -1:
        return GitReply(launched: true, exitCode: code, stdout: sinks[0],
                        stderr: sinks[1])
      sleep(2)

proc runGit(session: var Session; cwd: string; args: openArray[string];
            indexFile = ""; input = ""): GitReply =
  ## Run ``git -c <config>... <args>`` in ``cwd``. The inherited environment
  ## is kept (inside a commit's hook, ``GIT_INDEX_FILE`` IS the index being
  ## committed), and ``indexFile`` overrides it for one command.
  var overrides: seq[(string, string)]
  if indexFile.len > 0:
    overrides.add ("GIT_INDEX_FILE", indexFile)
  var gitArgs: seq[string]
  for setting in CommandConfiguration:
    gitArgs.add ["-c", setting]
  gitArgs.add args
  let env = commandEnvironment(overrides)
  when defined(windows):
    try:
      var process = uncontrolledStartProcess(session.git.binary, cwd, gitArgs,
        env, {poUsePath})
      try:
        result = drainProcess(process, input)
      finally:
        process.close()
    except OSError as error:
      result = GitReply(launched: false, stderr: error.msg)
  else:
    # The shell only redirects; every argument travels as a positional
    # parameter, so nothing is ever quoted or re-parsed.
    let inPath = session.nextScratchPath("stdin")
    let outPath = session.nextScratchPath("stdout")
    let errPath = session.nextScratchPath("stderr")
    try:
      writeFile(inPath, input)
      var process = uncontrolledStartProcess("/bin/sh", cwd,
        @["-c", "exec <\"$1\" >\"$2\" 2>\"$3\"; shift 3; exec \"$@\"", "sh",
          inPath, outPath, errPath, session.git.binary] & gitArgs,
        env, {})
      var code: int
      try:
        code = process.waitForExit()
      finally:
        process.close()
      result = GitReply(launched: true, exitCode: code,
                        stdout: readAndRemove(outPath),
                        stderr: readAndRemove(errPath))
      # The shell's `exec` failing (126: not executable, 127: not found)
      # means git never ran; say so rather than report git's "failure".
      if code in [126, 127] and result.stdout.len == 0 and
         session.git.binary in result.stderr:
        result.launched = false
    except OSError, IOError:
      result = GitReply(launched: false, stderr: getCurrentExceptionMsg())
    finally:
      for path in [inPath, outPath, errPath]:
        try: removeFile(path)
        except OSError: discard

type
  GitStep = object
    ok: bool
    launched: bool
    stdout: string
    failure: string

proc step(session: var Session; cwd: string; args: openArray[string];
          indexFile = ""; input = ""): GitStep =
  ## ``runGit``, with every way it can fail turned into a sentence.
  let reply = session.runGit(cwd, args, indexFile, input)
  let shown = "`git " & args.join(" ") & "`"
  if not reply.launched:
    return GitStep(failure: "could not run " & shown & " with `" &
      session.git.binary & "`: " & reply.stderr.strip())
  if reply.exitCode != 0:
    return GitStep(launched: true, failure: shown & " failed (exit " &
      $reply.exitCode & "): " & reply.stderr.strip())
  GitStep(ok: true, launched: true, stdout: reply.stdout)

proc singleLine(output: string): string =
  ## The one line a plumbing command printed, without its terminator only:
  ## a path may legitimately end in spaces.
  result = output
  result.stripLineEnd()

proc nulRecords(output: string): seq[string] =
  ## ``-z`` output as records; the final record is NUL-terminated.
  result = output.split('\0')
  if result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

proc openSession(git: ContentIdGit): tuple[ok: bool; session: Session;
                                          failure: string] =
  try:
    let dir = createTempDir("repro-content-id-", "")
    (true, Session(git: git, scratch: dir), "")
  except OSError, IOError:
    (false, Session(), "could not create a temporary directory for the " &
      "computation: " & getCurrentExceptionMsg())

proc closeSession(session: Session) =
  if session.scratch.len > 0:
    try:
      removeDir(session.scratch)
    except OSError:
      discard

# ---------------------------------------------------------------------------
# States with no content id (Content-Id §3)
# ---------------------------------------------------------------------------

type
  ContentStateKind* = enum
    ## The states Content-Id §5 computes an id for.
    cskWorkingTree
      ## The tracked files as they are in the working tree, computed in a
      ## temporary index: what a producer certifies, and what a status
      ## display shows.
    cskIndex
      ## The index being committed: what ``git write-tree`` returns for the
      ## index git uses here, honouring the ``GIT_INDEX_FILE`` git sets for
      ## ``commit -a`` and ``commit <paths>``. What a pre-commit gate checks.
    cskCommit
      ## ``<revision>^{tree}``. Works in a bare repository.

  ContentState* = object
    kind*: ContentStateKind
    revision*: string
      ## ``cskCommit`` only.

proc workingTreeState*(): ContentState = ContentState(kind: cskWorkingTree)
proc indexState*(): ContentState = ContentState(kind: cskIndex)
proc commitState*(revision: string): ContentState =
  ContentState(kind: cskCommit, revision: revision)

type
  ProbeResult* = object
    ok*: bool
      ## ``false`` when the probe itself failed; ``failure`` says why.
    findings*: seq[NoContentIdFinding]
      ## Empty when the state has an honest id.
    failure*: string

proc pathPresent(path: string): bool =
  ## Anything at ``path``: a file, a directory, or a symlink, dangling or not.
  fileExists(path) or dirExists(path) or symlinkExists(path)

proc probeWorkingTree(session: var Session; toplevel, indexFile: string;
                      scope: openArray[string]): ProbeResult =
  ## Every §3 state among the in-scope entries of ``indexFile`` (a COPY of
  ## the user's index) and the working tree, each with all of its paths.
  var unmerged, assumeUnchanged, skipPresent, gitlinks: seq[string]
  # `ls-files -s -v`: `<tag> SP <mode> SP <object> SP <stage> TAB <path>`.
  # A lowercase tag is assume-unchanged, `S`/`s` is skip-worktree, a non-zero
  # stage is unmerged (git-ls-files(1), `-t` and `-v`). The filesystem
  # monitor, which would also lowercase tags, is off for every command.
  let listing = session.step(toplevel,
    @["--literal-pathspecs", "ls-files", "-z", "-s", "-v", "--"] & @scope,
    indexFile)
  if not listing.ok:
    return ProbeResult(failure: listing.failure)
  for record in nulRecords(listing.stdout):
    let tab = record.find('\t')
    let fields = (if tab < 0: @[] else: record[0 ..< tab].split(' '))
    if fields.len != 4 or fields[0].len != 1:
      return ProbeResult(failure: "`git ls-files -s -v` printed a record " &
        "this recipe cannot read: " & record.escape())
    let tag = fields[0][0]
    let path = record[tab + 1 .. ^1]
    if fields[3] != "0":
      unmerged.add path
      continue
    if tag in {'a'..'z'}:
      assumeUnchanged.add path
    if tag in {'S', 's'} and pathPresent(toplevel / path):
      # Absent is how a sparse checkout leaves a skip-worktree entry, and then
      # the indexed content IS the content. Only a present file is one git
      # has been told not to look at.
      skipPresent.add path
    if fields[1] == "160000":
      gitlinks.add path

  # A nested repository is identified by its checked-out revision alone, so
  # modified content inside it is not represented. Only `git status` looks
  # inside, so it is asked only when the scope holds a gitlink. The `<sub>`
  # field of a porcelain v2 record is `S<c><m><u>`; `m` is "has tracked
  # changes". Untracked files inside are not modified content, just as
  # untracked files at the top level are reported apart rather than refused.
  var modified: seq[string]
  if gitlinks.len > 0:
    let status = session.step(toplevel,
      @["--literal-pathspecs", "status", "--porcelain=v2", "-z",
        "--untracked-files=no", "--ignore-submodules=none", "--no-renames",
        "--"] & @scope,
      indexFile)
    if not status.ok:
      return ProbeResult(failure: status.failure)
    let records = nulRecords(status.stdout)
    var i = 0
    while i < records.len:
      let record = records[i]
      inc i
      if record.startsWith("1 ") or record.startsWith("2 "):
        # Type 1 has 8 fields before the path; type 2 has 9 and is followed
        # by its original path as a separate record.
        let fixed = (if record[0] == '1': 8 else: 9)
        let fields = record.split(' ', maxsplit = fixed)
        if fields.len != fixed + 1:
          return ProbeResult(failure: "`git status --porcelain=v2` printed " &
            "a record this recipe cannot read: " & record.escape())
        let sub = fields[2]
        if sub.len == 4 and sub[0] == 'S' and sub[2] == 'M':
          modified.add fields[fixed]
        if record[0] == '2':
          inc i

  result.ok = true
  for (reason, paths) in [(ncrUnmergedEntries, unmerged),
                          (ncrAssumeUnchanged, assumeUnchanged),
                          (ncrSkipWorktreePresent, skipPresent),
                          (ncrNestedRepositoryModified, modified)]:
    if paths.len > 0:
      result.findings.add NoContentIdFinding(reason: reason,
                                             paths: sortedUnique(paths))

proc probeUnmerged(session: var Session; toplevel, indexFile: string;
                   scope: openArray[string]): ProbeResult =
  ## The one §3 state that applies to an index being committed. Flags that
  ## hide the working tree do not matter there: the index is what the commit
  ## records.
  let listing = session.step(toplevel,
    @["--literal-pathspecs", "ls-files", "-z", "--unmerged", "--"] & @scope,
    indexFile)
  if not listing.ok:
    return ProbeResult(failure: listing.failure)
  var paths: seq[string]
  for record in nulRecords(listing.stdout):
    let tab = record.find('\t')
    if tab < 0:
      return ProbeResult(failure: "`git ls-files --unmerged` printed a " &
        "record this recipe cannot read: " & record.escape())
    paths.add record[tab + 1 .. ^1]
  result.ok = true
  if paths.len > 0:
    result.findings.add NoContentIdFinding(reason: ncrUnmergedEntries,
                                           paths: sortedUnique(paths))

type
  CopiedIndex = object
    ok: bool
    toplevel: string
    path: string
    failure: string

proc copyUserIndex(session: var Session; repository: string): CopiedIndex =
  ## The working tree's top level, and a copy of the index git uses there in
  ## the session's scratch directory. A repository with no index tracks
  ## nothing; its copy is an empty index.
  let top = session.step(repository, ["rev-parse", "--show-toplevel"])
  if not top.ok:
    return CopiedIndex(failure: "`" & repository & "` is not inside a git " &
      "working tree: " & top.failure)
  result.toplevel = singleLine(top.stdout)
  # `--git-path index` honours GIT_INDEX_FILE, so "what is tracked" is the
  # index git itself would use here: the one being committed, inside a hook.
  let location = session.step(result.toplevel,
    ["rev-parse", "--path-format=absolute", "--git-path", "index"])
  if not location.ok:
    return CopiedIndex(failure: location.failure)
  let source = singleLine(location.stdout)
  result.path = session.scratch / "index"
  if fileExists(source):
    try:
      copyFile(source, result.path)
    except OSError, IOError:
      return CopiedIndex(failure: "could not copy the index `" & source &
        "` to a temporary file: " & getCurrentExceptionMsg())
  else:
    let empty = session.step(result.toplevel, ["read-tree", "--empty"],
                             result.path)
    if not empty.ok:
      return CopiedIndex(failure: empty.failure)
  result.ok = true

proc validScope(scope: openArray[string]): string =
  for prefix in scope:
    let problem = scopePathProblem(prefix)
    if problem.len > 0:
      return problem
  ""

proc probeNoContentId*(repository: string; scope: openArray[string] = [];
                       git = defaultContentIdGit()): ProbeResult =
  ## The §3 states of the working tree containing ``repository``, within
  ## ``scope``: unmerged entries, ``assume-unchanged`` entries,
  ## ``skip-worktree`` entries whose file is present, and nested repositories
  ## with modified content. Each finding names its paths; ``remedy`` says
  ## what to do. Reads a copy of the index; writes nothing in the repository.
  let problem = validScope(scope)
  if problem.len > 0:
    return ProbeResult(failure: problem)
  var (opened, session, failure) = openSession(git)
  if not opened:
    return ProbeResult(failure: failure)
  try:
    let copied = session.copyUserIndex(repository)
    if not copied.ok:
      return ProbeResult(failure: copied.failure)
    session.probeWorkingTree(copied.toplevel, copied.path, scope)
  finally:
    closeSession(session)

# ---------------------------------------------------------------------------
# Computing an id in a repository (Content-Id §4, §5)
# ---------------------------------------------------------------------------

proc repositoryObjectFormat(session: var Session; repository: string):
    tuple[ok: bool; algorithm: ContentAlgorithm; failure: string] =
  let format = session.step(repository, ["rev-parse", "--show-object-format"])
  if not format.ok:
    if not format.launched:
      return (false, caGitTreeSha1, format.failure)
    return (false, caGitTreeSha1, "`" & repository & "` is not a git " &
      "repository: " & format.failure)
  case singleLine(format.stdout)
  of "sha1": (true, caGitTreeSha1, "")
  of "sha256": (true, caGitTreeSha256, "")
  else:
    (false, caGitTreeSha1, "git reports object format `" &
      singleLine(format.stdout) & "`, over which no content id is defined")

proc repositoryContentAlgorithm*(repository: string;
                                 git = defaultContentIdGit()):
    tuple[ok: bool; algorithm: ContentAlgorithm; failure: string] =
  ## The ``git-tree-*`` algorithm matching the repository's object format:
  ## the one a producer should use (§4).
  var (opened, session, failure) = openSession(git)
  if not opened:
    return (false, caGitTreeSha1, failure)
  try:
    session.repositoryObjectFormat(repository)
  finally:
    closeSession(session)

proc treeIdProblem(tree: string; format: ContentAlgorithm): string =
  ## Anything but a full lowercase object id of the repository's format is a
  ## failure, never an id.
  if parseContentId(formatContentId(format, tree)).form != cifWellFormed:
    "git returned `" & tree & "` where a " & $format & " tree id was expected"
  else:
    ""

proc manifestOfTree(session: var Session; cwd, tree: string): ContentIdResult =
  ## ``manifest-v1-sha256`` of a tree that already holds exactly the in-scope
  ## entries at their full paths. Its blobs are the content "as the VCS would
  ## record it" (§2).
  let name = $caManifestV1Sha256
  let listing = session.step(cwd, ["ls-tree", "-r", "-z", "--full-tree", tree])
  if not listing.ok:
    return failed(name, listing.failure)
  var entries: seq[ContentEntry]
  var blobs: seq[(int, string)]
  for record in nulRecords(listing.stdout):
    # `<mode> SP <type> SP <object> TAB <path>` (git-ls-tree(1)).
    let tab = record.find('\t')
    let fields = (if tab < 0: @[] else: record[0 ..< tab].split(' '))
    if fields.len != 3:
      return failed(name, "`git ls-tree` printed a record this recipe " &
        "cannot read: " & record.escape())
    let path = record[tab + 1 .. ^1]
    case fields[1]
    of "blob":
      blobs.add (entries.len, fields[2])
      entries.add ContentEntry(path: path, mode: fields[0])
    of "commit":
      # A gitlink: the nested repository's revision, as git spells it.
      entries.add ContentEntry(path: path, mode: fields[0], content: fields[2])
    else:
      return failed(name, "`git ls-tree -r` listed a " & fields[1] &
        " entry `" & path & "`, which a manifest has no record for")
  if blobs.len > 0:
    # One `cat-file --batch` for every blob: `<object> SP <type> SP <size> LF
    # <contents> LF` per request.
    var request = ""
    for (_, objectId) in blobs:
      request.add objectId & "\n"
    let batch = session.step(cwd, ["cat-file", "--batch"], input = request)
    if not batch.ok:
      return failed(name, batch.failure)
    var at = 0
    let output = batch.stdout
    for (index, objectId) in blobs:
      let eol = output.find('\n', at)
      let header = (if eol < 0: @[] else: output[at ..< eol].split(' '))
      if header.len != 3 or header[0] != objectId or header[1] != "blob":
        return failed(name, "`git cat-file --batch` did not return blob " &
          objectId)
      let size = parseInt(header[2])
      if eol + 1 + size + 1 > output.len:
        return failed(name, "`git cat-file --batch` returned blob " &
          objectId & " truncated")
      entries[index].content = output[eol + 1 ..< eol + 1 + size]
      at = eol + 1 + size + 1
  manifestV1Sha256(entries)

proc computeContentId*(repository: string; state: ContentState;
                       algorithm: ContentAlgorithm;
                       scope: openArray[string] = [];
                       git = defaultContentIdGit()): ContentIdResult =
  ## The content id of ``state`` in the git repository containing
  ## ``repository``, in ``algorithm``, over ``scope`` (empty: the whole
  ## repository).
  ##
  ## The unscoped tree ``T`` comes first:
  ##
  ## * a working tree: the user's index is COPIED; in the copy only, the §3
  ##   states are looked for (and returned instead of an id), the copy is
  ##   dated ``StatDistrustTime``, ``git add --update`` takes every tracked
  ##   entry's working-tree content and drops deleted ones while adding
  ##   nothing untracked, and ``git write-tree`` gives ``T``. A repository
  ##   with no index tracks nothing: the empty tree;
  ## * the index being committed: the same copy, unmerged entries refused,
  ##   then ``git write-tree`` (which stores a cache-tree back into the index
  ##   it reads, so it reads the copy);
  ## * a commit: ``<revision>^{tree}``. Nothing to normalise or refuse.
  ##
  ## A scope then keeps only the in-scope entries of ``T`` AT THEIR FULL
  ## PATHS: ``read-tree --empty``, ``ls-tree -r -z --full-tree`` with literal
  ## pathspecs, ``update-index -z --index-info``, ``write-tree``. That is not
  ## the subtree ``T:<path>``, which has lost its path. A scope matching
  ## nothing yields the empty tree.
  ##
  ## ``git-tree-*`` in the other object format is ``cioCannotCompute``.
  let name = $algorithm
  let problem = validScope(scope)
  if problem.len > 0:
    return failed(name, problem)
  if state.kind == cskCommit and
     (state.revision.len == 0 or state.revision.startsWith("-")):
    # A leading `-` would be read as an option.
    return failed(name, "`" & state.revision & "` is not a revision")

  var (opened, session, failure) = openSession(git)
  if not opened:
    return failed(name, failure)
  try:
    let format = session.repositoryObjectFormat(repository)
    if not format.ok:
      return failed(name, format.failure)
    if algorithm != caManifestV1Sha256 and algorithm != format.algorithm:
      return cannotCompute(name, name & " cannot be computed in this " &
        "repository: its object format makes its trees " & $format.algorithm &
        " ids")

    var cwd = repository
    var tree: string
    case state.kind
    of cskCommit:
      let resolved = session.step(cwd,
        ["rev-parse", "--verify", "--quiet", state.revision & "^{tree}"])
      if not resolved.ok:
        return failed(name, "`" & state.revision & "` does not name a " &
          "commit or tree in this repository")
      tree = singleLine(resolved.stdout)
    of cskWorkingTree, cskIndex:
      let copied = session.copyUserIndex(repository)
      if not copied.ok:
        return failed(name, copied.failure)
      cwd = copied.toplevel
      let probe =
        if state.kind == cskWorkingTree:
          session.probeWorkingTree(cwd, copied.path, scope)
        else:
          session.probeUnmerged(cwd, copied.path, scope)
      if not probe.ok:
        return failed(name, probe.failure)
      if probe.findings.len > 0:
        return noContentId(name, probe.findings)
      if state.kind == cskWorkingTree:
        try:
          setLastModificationTime(copied.path, fromUnix(StatDistrustTime))
        except OSError:
          return failed(name, "could not date the temporary index: " &
            getCurrentExceptionMsg())
        # No pathspec: since git 2.0 `add --update` without one covers the
        # whole tree, which is what `-- :/` spells, and it stays so under an
        # inherited GIT_LITERAL_PATHSPECS that would make `:/` a file name.
        let update = session.step(cwd, ["add", "--update"], copied.path)
        if not update.ok:
          return failed(name, update.failure)
      let written = session.step(cwd, ["write-tree"], copied.path)
      if not written.ok:
        return failed(name, written.failure)
      tree = singleLine(written.stdout)
    let treeProblem = treeIdProblem(tree, format.algorithm)
    if treeProblem.len > 0:
      return failed(name, treeProblem)

    if scope.len > 0:
      let scoped = session.scratch / "scoped-index"
      let empty = session.step(cwd, ["read-tree", "--empty"], scoped)
      if not empty.ok:
        return failed(name, empty.failure)
      let listed = session.step(cwd,
        @["--literal-pathspecs", "ls-tree", "-r", "-z", "--full-tree", tree,
          "--"] & @scope)
      if not listed.ok:
        return failed(name, listed.failure)
      let staged = session.step(cwd, ["update-index", "-z", "--index-info"],
                                scoped, input = listed.stdout)
      if not staged.ok:
        return failed(name, staged.failure)
      let written = session.step(cwd, ["write-tree"], scoped)
      if not written.ok:
        return failed(name, written.failure)
      tree = singleLine(written.stdout)
      let scopedProblem = treeIdProblem(tree, format.algorithm)
      if scopedProblem.len > 0:
        return failed(name, scopedProblem)

    if algorithm == caManifestV1Sha256:
      return session.manifestOfTree(cwd, tree)
    computed(format.algorithm, tree)
  finally:
    closeSession(session)

proc computeContentId*(repository: string; state: ContentState;
                       algorithmName: string;
                       scope: openArray[string] = [];
                       git = defaultContentIdGit()): ContentIdResult =
  ## As above, for an algorithm named by its identifier, as a certificate
  ## spells it. An identifier outside §4 is ``cioCannotCompute``.
  let (known, algorithm) = lookupContentAlgorithm(algorithmName)
  if not known:
    return cannotCompute(algorithmName, "`" & algorithmName & "` is not a " &
      "content id algorithm this implementation computes")
  computeContentId(repository, state, algorithm, scope, git)

# ---------------------------------------------------------------------------
# Evaluating a claimed id
# ---------------------------------------------------------------------------

type
  ClaimEvaluation* = enum
    ceMatches
      ## The state's id in the claim's algorithm equals the claim.
    ceDiffers
      ## It was computed, and it is different.
    ceMalformed
      ## The claim is not a well-formed id: decidably invalid.
    ceCannotCompute
      ## The claim's algorithm cannot be computed here (unknown, or the other
      ## git object format). Report as unverifiable, never as a mismatch.
    ceNoContentId
      ## The state has no honest id (§3); ``computed.findings`` says why.
    ceFailed
      ## The computation failed; ``computed.reason`` says why.

  ClaimResult* = object
    evaluation*: ClaimEvaluation
    parsed*: ParsedContentId
    computed*: ContentIdResult

proc evaluateClaimedContentId*(claimed, repository: string;
                               state: ContentState;
                               scope: openArray[string] = [];
                               git = defaultContentIdGit()): ClaimResult =
  ## Compute ``state``'s id in ``claimed``'s own algorithm and compare the
  ## two as strings. Ids of different algorithms are never compared, and a
  ## malformed claim is never repaired into one that could match.
  result.parsed = parseContentId(claimed)
  case result.parsed.form
  of cifMalformed:
    result.evaluation = ceMalformed
  of cifUnknownAlgorithm:
    result.evaluation = ceCannotCompute
    result.computed = computeContentId(repository, state,
      result.parsed.algorithmName, scope, git)
  of cifWellFormed:
    result.computed = computeContentId(repository, state,
      result.parsed.algorithm, scope, git)
    result.evaluation =
      case result.computed.outcome
      of cioComputed:
        if result.computed.id == claimed: ceMatches else: ceDiffers
      of cioCannotCompute: ceCannotCompute
      of cioNoContentId: ceNoContentId
      of cioFailed: ceFailed
