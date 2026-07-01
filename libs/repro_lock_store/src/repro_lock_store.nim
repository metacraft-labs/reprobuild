## ``repro_lock_store`` — the abstract Lock/Manifest store interface and
## its pluggable backends (Workspace-Manifest-Optional.milestones.org MO-3,
## Workspace-Manifests.md §"The lock/manifest store abstraction").
##
## A single *logical* lock/manifest store model — a database-like interface
## for reading membership/manifest layers, reading the latest lock records,
## writing + publishing lock records, and reading/writing participation
## evidence — backed by several interchangeable mediums:
##
##   - **committed-file**  — lock records as files in a repo-local directory
##     (the MO-1 committed-lock store family; needs no manifest repo).
##   - **git-checkout**    — the ``.repo/manifests`` ``locks/...`` layout
##     (defined in ``repro_cli_support`` as ``GitCheckoutLockStore`` so it
##     can DELEGATE to the existing byte-identical publish/read procs).
##   - **git-notes**       — a ``refs/notes/...`` namespace attaching records
##     to commits without a separate checkout (reuses the TC-2 notes pattern).
##   - **separate-branch** — a gh-pages-style orphan branch holding the
##     records (for VCS that cannot attach metadata to a commit).
##   - **external-CLI**    — an external program with a documented CLI/JSON
##     contract that can be backed by a real database.
##
## Store operations run **only when an operation actually needs a store**: an
## all-public, committed-lock-only workspace never constructs a backend.
##
## ## The store record
##
## Every backend persists the same *logical* unit: a ``StoreLockRecord`` —
## the identity tuple ``(project, repo, sha)`` plus the serialized lock TOML
## ``body``. The record is framed into a single self-describing blob by
## ``encodeRecord`` / ``decodeRecord`` so every medium round-trips the FULL
## identity + body (not just the body), regardless of how the medium keys it.
## Participation evidence (``WorkspaceVcsEvidence``) is persisted as the
## canonical SSZ envelope, base64-wrapped so text-only mediums (git-notes,
## external-CLI JSON) carry it losslessly.

import std/[base64, json, options, os, osproc, streams, strtabs, strutils, tables]

import evidence as workspaceVcsEvidence

export workspaceVcsEvidence.WorkspaceVcsEvidence

const
  StoreRecordSchemaV1* = "reprobuild.lockstore.record.v1"
    ## ``schema`` line of the framed store record.
  ExternalCliContractSchemaV1* = "reprobuild.lockstore.external-cli.v1"
    ## ``schema`` field of the external-CLI request/response JSON.
  recordBodyMarker = "@@reprobuild-lockstore-body@@"
    ## Sentinel line separating the record header from the verbatim body.
  lockStoreNotesRef* = "refs/notes/reprobuild/locks"
    ## git-notes carrier ref for lock records (parallel to the TC-2
    ## ``refs/notes/reprobuild/certificates`` cert carrier).
  separateBranchRef* = "refs/heads/reprobuild-lockstore"
    ## The orphan branch the separate-branch backend commits records onto.

type
  StoreLockKey* = object
    ## Identity of one lock record. ``repo`` is the trigger repo and
    ## ``sha`` the trigger commit — the same anchor the git-checkout
    ## ``locks/<project>/<repo>/<sha>.toml`` layout keys on.
    project*: string
    repo*: string
    sha*: string

  StoreLockRecord* = object
    ## One persisted lock record: identity + the serialized lock TOML body.
    key*: StoreLockKey
    body*: string

  StorePutOutcome* = enum
    spoOk               ## Record written (and published where applicable).
    spoNothing          ## Nothing to write / publish.
    spoRefusedDirty     ## Refused because the medium was dirty outside scope.
    spoNotPublishable   ## The medium is not configured to publish.
    spoFailed           ## A genuine write/publish attempt failed.

  StorePutResult* = object
    outcome*: StorePutOutcome
    diagnostic*: string

  LockStore* = ref object of RootObj
    ## Abstract lock/manifest store. Subclasses implement one medium.

  StoreError* = object of CatchableError

proc ok*(): StorePutResult = StorePutResult(outcome: spoOk)
proc failed*(msg: string): StorePutResult =
  StorePutResult(outcome: spoFailed, diagnostic: msg)

# ---------------------------------------------------------------------------
# Framed record + evidence codecs (medium-independent)
# ---------------------------------------------------------------------------

proc tomlEscape(s: string): string =
  result = newStringOfCap(s.len + 2)
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)

proc tomlUnescape(raw: string): string =
  result = newStringOfCap(raw.len)
  var i = 0
  while i < raw.len:
    let ch = raw[i]
    if ch == '\\' and i + 1 < raw.len:
      case raw[i + 1]
      of '\\': result.add('\\')
      of '"': result.add('"')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      else: result.add(raw[i + 1])
      i += 2
    else:
      result.add(ch); inc i

proc scalar(rhs: string): string =
  let s = rhs.strip()
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    tomlUnescape(s[1 ..< s.high])
  else: s

proc encodeRecord*(rec: StoreLockRecord): string =
  ## Frame a record into a single self-describing blob. The header carries
  ## the full identity tuple; everything after the ``recordBodyMarker``
  ## line is the verbatim lock body (so a body that itself contains ``=``
  ## lines round-trips untouched).
  result = "schema = \"" & StoreRecordSchemaV1 & "\"\n"
  result.add("project = \"" & tomlEscape(rec.key.project) & "\"\n")
  result.add("repo = \"" & tomlEscape(rec.key.repo) & "\"\n")
  result.add("sha = \"" & tomlEscape(rec.key.sha) & "\"\n")
  result.add(recordBodyMarker & "\n")
  result.add(rec.body)

proc decodeRecord*(blob: string): StoreLockRecord =
  ## Inverse of ``encodeRecord``. Raises ``StoreError`` when the blob is not
  ## a framed store record (wrong/missing schema or no body marker).
  let markerIdx = blob.find(recordBodyMarker & "\n")
  if markerIdx < 0:
    raise newException(StoreError, "store record has no body marker")
  let header = blob[0 ..< markerIdx]
  result.body = blob[(markerIdx + recordBodyMarker.len + 1) .. ^1]
  var sawSchema = false
  for rawLine in header.splitLines():
    let line = rawLine.strip()
    if line.len == 0: continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0 ..< eq].strip()
    let val = scalar(line[eq + 1 .. ^1])
    case key
    of "schema":
      if val != StoreRecordSchemaV1:
        raise newException(StoreError,
          "unknown store record schema '" & val & "'")
      sawSchema = true
    of "project": result.key.project = val
    of "repo": result.key.repo = val
    of "sha": result.key.sha = val
    else: discard
  if not sawSchema:
    raise newException(StoreError, "store record missing schema line")

proc encodeEvidenceBlob*(ev: seq[WorkspaceVcsEvidence]): string =
  ## Base64 of the canonical SSZ evidence envelope (the persistence form
  ## the evidence schema mandates — NEVER the JSON view).
  base64.encode(workspaceVcsEvidence.toSsz(ev))

proc decodeEvidenceBlob*(blob: string): seq[WorkspaceVcsEvidence] =
  let trimmed = blob.strip()
  if trimmed.len == 0: return @[]
  let raw = base64.decode(trimmed)
  var bytes = newSeq[byte](raw.len)
  for i, ch in raw: bytes[i] = byte(ch)
  workspaceVcsEvidence.fromSsz(bytes)

proc shasFromBody*(body: string): Table[string, string] =
  ## Decode a lock TOML body into the ``path -> revision`` map the
  ## gate/check consume. Hand-parses the flat ``[[repo]]`` array the lock
  ## writer emits (``path`` / ``revision`` keys); tolerant of a body that
  ## is not a workspace lock (returns an empty table).
  result = initTable[string, string]()
  var curPath = ""
  var curRev = ""
  # A template (not a nested proc) so it can mutate ``result`` / the locals
  # inline without a closure capturing ``result`` (which Nim rejects).
  template flush() =
    if curPath.len > 0 and curRev.len > 0:
      result[curPath] = curRev
    curPath = ""; curRev = ""
  for rawLine in body.splitLines():
    let line = rawLine.strip()
    if line == "[[repo]]":
      flush()
      continue
    if line.startsWith("[") and line != "[[repo]]":
      flush()
      continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0 ..< eq].strip()
    let val = scalar(line[eq + 1 .. ^1])
    case key
    of "path": curPath = val
    of "revision": curRev = val
    else: discard
  flush()

# ---------------------------------------------------------------------------
# Abstract interface
# ---------------------------------------------------------------------------

method backendId*(s: LockStore): string {.base.} = "abstract"

method putLock*(s: LockStore; rec: StoreLockRecord): StorePutResult {.base.} =
  ## Write a lock record into the store. Idempotent at a given key.
  failed("putLock not implemented for abstract LockStore")

method latestLock*(s: LockStore; project, repo: string):
    Option[StoreLockRecord] {.base.} =
  ## The newest lock record for ``(project, repo)``, or ``none`` when absent.
  none(StoreLockRecord)

method latestLockAny*(s: LockStore; project: string):
    Option[StoreLockRecord] {.base.} =
  ## The newest lock record across every repo of ``project``.
  none(StoreLockRecord)

method latestLockShas*(s: LockStore; project: string):
    tuple[shas: Table[string, string]; lockKey: StoreLockKey] {.base.} =
  ## ``path -> revision`` of the newest lock across all repos of
  ## ``project`` (the gate/check stage-5 read), plus the record key.
  let latest = s.latestLockAny(project)
  if latest.isSome:
    (shas: shasFromBody(latest.get().body), lockKey: latest.get().key)
  else:
    (shas: initTable[string, string](), lockKey: StoreLockKey())

method publishPending*(s: LockStore): StorePutResult {.base.} =
  ## Publish any locally-written-but-unpublished records to the medium's
  ## remote. Mediums that publish on ``putLock`` report ``spoNothing``.
  StorePutResult(outcome: spoNothing)

method putEvidence*(s: LockStore; project, repo: string;
    ev: seq[WorkspaceVcsEvidence]): StorePutResult {.base.} =
  failed("putEvidence not implemented for abstract LockStore")

method getEvidence*(s: LockStore; project, repo: string):
    seq[WorkspaceVcsEvidence] {.base.} = @[]

method manifestLayerRoots*(s: LockStore): seq[string] {.base.} =
  ## Membership/manifest-layer roots this store exposes. Only the
  ## git-checkout backend carries manifest layers (``repos/`` / ``projects/``
  ## / ``variants/``); the record-only backends return an empty seq.
  @[]

method storeLocationLabel*(s: LockStore): string {.base.} =
  ## HL-3 — a human-readable location for the backend (the on-disk root, the
  ## program path, …) so a refusal remedy can name WHERE the backend lives.
  ## The base returns the empty string; concrete backends override.
  ""

# ---------------------------------------------------------------------------
# Shared git runner
# ---------------------------------------------------------------------------

proc runGit(gitBin: string; args: openArray[string];
            extraEnv: openArray[(string, string)] = []):
    tuple[code: int; output: string] =
  ## Run git with stderr folded into stdout. ``extraEnv`` overlays the
  ## inherited environment (used by the separate-branch backend to point
  ## ``GIT_INDEX_FILE`` at a scratch index).
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  for (k, v) in extraEnv: env[k] = v
  var p = startProcess(gitBin, args = @args, env = env,
    options = {poStdErrToStdOut, poUsePath})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (code: code, output: output)

# ---------------------------------------------------------------------------
# Backend 1 — committed-file
# ---------------------------------------------------------------------------

type
  CommittedFileLockStore* = ref object of LockStore
    ## Lock records as plain files under ``baseDir`` (a repo-local,
    ## committable directory). "Latest" is tracked by a plain-text pointer
    ## file per ``(project, repo)`` and per project — git's own ref model,
    ## not a JSON index.
    baseDir*: string

proc newCommittedFileLockStore*(baseDir: string): CommittedFileLockStore =
  CommittedFileLockStore(baseDir: absolutePath(baseDir))

proc cfRecordPath(s: CommittedFileLockStore; k: StoreLockKey): string =
  s.baseDir / "locks" / k.project / k.repo / (k.sha & ".rec")

method backendId*(s: CommittedFileLockStore): string = "committed-file"

method storeLocationLabel*(s: CommittedFileLockStore): string = s.baseDir

method putLock*(s: CommittedFileLockStore;
    rec: StoreLockRecord): StorePutResult =
  try:
    let path = cfRecordPath(s, rec.key)
    createDir(parentDir(path))
    writeFile(path, encodeRecord(rec))
    # Latest pointers: a per-repo HEAD (the sha) and a per-project HEAD
    # (repo TAB sha) so latestLock / latestLockAny are O(1) reads.
    writeFile(s.baseDir / "locks" / rec.key.project / rec.key.repo / "HEAD",
      rec.key.sha & "\n")
    let projDir = s.baseDir / "locks" / rec.key.project
    createDir(projDir)
    writeFile(projDir / "HEAD", rec.key.repo & "\t" & rec.key.sha & "\n")
    ok()
  except CatchableError as err:
    failed(err.msg)

method latestLock*(s: CommittedFileLockStore; project, repo: string):
    Option[StoreLockRecord] =
  let headPath = s.baseDir / "locks" / project / repo / "HEAD"
  if not fileExists(headPath): return none(StoreLockRecord)
  let sha = readFile(headPath).strip()
  let recPath = cfRecordPath(s, StoreLockKey(project: project, repo: repo, sha: sha))
  if not fileExists(recPath): return none(StoreLockRecord)
  some(decodeRecord(readFile(recPath)))

method latestLockAny*(s: CommittedFileLockStore; project: string):
    Option[StoreLockRecord] =
  let headPath = s.baseDir / "locks" / project / "HEAD"
  if not fileExists(headPath): return none(StoreLockRecord)
  let parts = readFile(headPath).strip().split('\t')
  if parts.len != 2: return none(StoreLockRecord)
  latestLock(s, project, parts[0])

method putEvidence*(s: CommittedFileLockStore; project, repo: string;
    ev: seq[WorkspaceVcsEvidence]): StorePutResult =
  try:
    let dir = s.baseDir / "evidence" / project
    createDir(dir)
    writeFile(dir / (repo & ".ev"), encodeEvidenceBlob(ev))
    ok()
  except CatchableError as err:
    failed(err.msg)

method getEvidence*(s: CommittedFileLockStore; project, repo: string):
    seq[WorkspaceVcsEvidence] =
  let path = s.baseDir / "evidence" / project / (repo & ".ev")
  if not fileExists(path): return @[]
  decodeEvidenceBlob(readFile(path))

# ---------------------------------------------------------------------------
# Backend 2 — git-notes
# ---------------------------------------------------------------------------

type
  GitNotesLockStore* = ref object of LockStore
    ## Lock records attached as git notes (under ``lockStoreNotesRef``) to
    ## the trigger commit, with lightweight refs naming the latest commit
    ## per ``(project, repo)`` and per project. Reuses the TC-2 notes pattern.
    gitBin*: string
    repoPath*: string

proc newGitNotesLockStore*(gitBin, repoPath: string): GitNotesLockStore =
  GitNotesLockStore(gitBin: gitBin, repoPath: absolutePath(repoPath))

proc gnLatestRef(project, repo: string): string =
  "refs/reprobuild/lockstore/" & project & "/" & repo & "/latest"
proc gnLatestAnyRef(project: string): string =
  "refs/reprobuild/lockstore/" & project & "/latest"
proc gnEvidenceNotesRef(): string = "refs/notes/reprobuild/lock-evidence"

method backendId*(s: GitNotesLockStore): string = "git-notes"

method storeLocationLabel*(s: GitNotesLockStore): string = s.repoPath

method putLock*(s: GitNotesLockStore; rec: StoreLockRecord): StorePutResult =
  let blob = encodeRecord(rec)
  # Overwrite any prior note on this exact commit (a re-lock at the same
  # sha is idempotent).
  let add = runGit(s.gitBin, ["-C", s.repoPath, "notes", "--ref",
    lockStoreNotesRef, "add", "-f", "-m", blob, rec.key.sha])
  if add.code != 0:
    return failed("git notes add failed: " & add.output.strip())
  for refName in [gnLatestRef(rec.key.project, rec.key.repo),
                  gnLatestAnyRef(rec.key.project)]:
    let upd = runGit(s.gitBin,
      ["-C", s.repoPath, "update-ref", refName, rec.key.sha])
    if upd.code != 0:
      return failed("git update-ref " & refName & " failed: " &
        upd.output.strip())
  ok()

proc gnReadNoteAt(s: GitNotesLockStore; refName: string):
    Option[StoreLockRecord] =
  let rev = runGit(s.gitBin,
    ["-C", s.repoPath, "rev-parse", "--verify", "--quiet", refName])
  if rev.code != 0: return none(StoreLockRecord)
  let commit = rev.output.strip()
  if commit.len == 0: return none(StoreLockRecord)
  let show = runGit(s.gitBin,
    ["-C", s.repoPath, "notes", "--ref", lockStoreNotesRef, "show", commit])
  if show.code != 0: return none(StoreLockRecord)
  some(decodeRecord(show.output))

method latestLock*(s: GitNotesLockStore; project, repo: string):
    Option[StoreLockRecord] =
  gnReadNoteAt(s, gnLatestRef(project, repo))

method latestLockAny*(s: GitNotesLockStore; project: string):
    Option[StoreLockRecord] =
  gnReadNoteAt(s, gnLatestAnyRef(project))

method putEvidence*(s: GitNotesLockStore; project, repo: string;
    ev: seq[WorkspaceVcsEvidence]): StorePutResult =
  # Evidence rides as a note on the latest-locked commit for the repo so it
  # travels with the same single ref the lock record does.
  let rev = runGit(s.gitBin, ["-C", s.repoPath, "rev-parse", "--verify",
    "--quiet", gnLatestRef(project, repo)])
  if rev.code != 0:
    return failed("no locked commit to attach evidence to for " &
      project & "/" & repo)
  let commit = rev.output.strip()
  let add = runGit(s.gitBin, ["-C", s.repoPath, "notes", "--ref",
    gnEvidenceNotesRef(), "add", "-f", "-m", encodeEvidenceBlob(ev), commit])
  if add.code != 0:
    return failed("git notes add (evidence) failed: " & add.output.strip())
  ok()

method getEvidence*(s: GitNotesLockStore; project, repo: string):
    seq[WorkspaceVcsEvidence] =
  let rev = runGit(s.gitBin, ["-C", s.repoPath, "rev-parse", "--verify",
    "--quiet", gnLatestRef(project, repo)])
  if rev.code != 0: return @[]
  let commit = rev.output.strip()
  let show = runGit(s.gitBin, ["-C", s.repoPath, "notes", "--ref",
    gnEvidenceNotesRef(), "show", commit])
  if show.code != 0: return @[]
  decodeEvidenceBlob(show.output)

# ---------------------------------------------------------------------------
# Backend 3 — separate-branch (gh-pages-style orphan branch)
# ---------------------------------------------------------------------------

type
  SeparateBranchLockStore* = ref object of LockStore
    ## Lock records committed as files onto an orphan branch
    ## (``separateBranchRef``) WITHOUT touching the working branch. Built
    ## with low-level plumbing (hash-object / a scratch index / write-tree /
    ## commit-tree / update-ref) so the working tree is never disturbed.
    gitBin*: string
    repoPath*: string

proc newSeparateBranchLockStore*(gitBin, repoPath: string):
    SeparateBranchLockStore =
  SeparateBranchLockStore(gitBin: gitBin, repoPath: absolutePath(repoPath))

method backendId*(s: SeparateBranchLockStore): string = "separate-branch"

method storeLocationLabel*(s: SeparateBranchLockStore): string = s.repoPath

proc sbHashObject(s: SeparateBranchLockStore; content: string):
    tuple[ok: bool; sha, diag: string] =
  let tmp = s.repoPath / (".repro-lockstore-blob-" & $getCurrentProcessId())
  try:
    writeFile(tmp, content)
    let res = runGit(s.gitBin,
      ["-C", s.repoPath, "hash-object", "-w", tmp])
    if res.code != 0:
      return (false, "", "git hash-object failed: " & res.output.strip())
    (true, res.output.strip(), "")
  finally:
    if fileExists(tmp): removeFile(tmp)

proc sbCommitFiles(s: SeparateBranchLockStore;
    files: seq[(string, string)]; message: string): StorePutResult =
  ## Commit ``(path, content)`` pairs onto the orphan branch. Uses a scratch
  ## index so the developer's real index/working tree is untouched.
  let scratchIndex = s.repoPath / (".git" / ("repro-lockstore-index-" &
    $getCurrentProcessId()))
  let env = [("GIT_INDEX_FILE", scratchIndex)]
  try:
    # Seed the scratch index from the existing branch tip when present.
    let parentRev = runGit(s.gitBin, ["-C", s.repoPath, "rev-parse",
      "--verify", "--quiet", separateBranchRef])
    var parent = ""
    if parentRev.code == 0:
      parent = parentRev.output.strip()
      let readTree = runGit(s.gitBin,
        ["-C", s.repoPath, "read-tree", parent], env)
      if readTree.code != 0:
        return failed("git read-tree failed: " & readTree.output.strip())
    for (path, content) in files:
      let h = sbHashObject(s, content)
      if not h.ok: return failed(h.diag)
      let upd = runGit(s.gitBin, ["-C", s.repoPath, "update-index", "--add",
        "--cacheinfo", "100644," & h.sha & "," & path], env)
      if upd.code != 0:
        return failed("git update-index failed: " & upd.output.strip())
    let writeTree = runGit(s.gitBin, ["-C", s.repoPath, "write-tree"], env)
    if writeTree.code != 0:
      return failed("git write-tree failed: " & writeTree.output.strip())
    let tree = writeTree.output.strip()
    var commitArgs = @["-C", s.repoPath, "commit-tree", tree, "-m", message]
    if parent.len > 0:
      commitArgs.add("-p"); commitArgs.add(parent)
    let commit = runGit(s.gitBin, commitArgs)
    if commit.code != 0:
      return failed("git commit-tree failed: " & commit.output.strip())
    let newCommit = commit.output.strip()
    let updRef = runGit(s.gitBin,
      ["-C", s.repoPath, "update-ref", separateBranchRef, newCommit])
    if updRef.code != 0:
      return failed("git update-ref failed: " & updRef.output.strip())
    ok()
  finally:
    if fileExists(scratchIndex): removeFile(scratchIndex)

proc sbRecordPath(k: StoreLockKey): string =
  "locks/" & k.project & "/" & k.repo & "/" & k.sha & ".rec"

method putLock*(s: SeparateBranchLockStore;
    rec: StoreLockRecord): StorePutResult =
  sbCommitFiles(s, @[
    (sbRecordPath(rec.key), encodeRecord(rec)),
    ("locks/" & rec.key.project & "/" & rec.key.repo & "/HEAD",
     rec.key.sha & "\n"),
    ("locks/" & rec.key.project & "/HEAD",
     rec.key.repo & "\t" & rec.key.sha & "\n")],
    "lockstore: " & rec.key.project & "/" & rec.key.repo & "@" & rec.key.sha)

proc sbShow(s: SeparateBranchLockStore; path: string): Option[string] =
  let res = runGit(s.gitBin,
    ["-C", s.repoPath, "cat-file", "-p", separateBranchRef & ":" & path])
  if res.code != 0: return none(string)
  some(res.output)

method latestLock*(s: SeparateBranchLockStore; project, repo: string):
    Option[StoreLockRecord] =
  let head = sbShow(s, "locks/" & project & "/" & repo & "/HEAD")
  if head.isNone: return none(StoreLockRecord)
  let sha = head.get().strip()
  let rec = sbShow(s, sbRecordPath(
    StoreLockKey(project: project, repo: repo, sha: sha)))
  if rec.isNone: return none(StoreLockRecord)
  some(decodeRecord(rec.get()))

method latestLockAny*(s: SeparateBranchLockStore; project: string):
    Option[StoreLockRecord] =
  let head = sbShow(s, "locks/" & project & "/HEAD")
  if head.isNone: return none(StoreLockRecord)
  let parts = head.get().strip().split('\t')
  if parts.len != 2: return none(StoreLockRecord)
  latestLock(s, project, parts[0])

method putEvidence*(s: SeparateBranchLockStore; project, repo: string;
    ev: seq[WorkspaceVcsEvidence]): StorePutResult =
  sbCommitFiles(s, @[("evidence/" & project & "/" & repo & ".ev",
    encodeEvidenceBlob(ev))], "lockstore evidence: " & project & "/" & repo)

method getEvidence*(s: SeparateBranchLockStore; project, repo: string):
    seq[WorkspaceVcsEvidence] =
  let blob = sbShow(s, "evidence/" & project & "/" & repo & ".ev")
  if blob.isNone: return @[]
  decodeEvidenceBlob(blob.get())

# ---------------------------------------------------------------------------
# Backend 5 — external-CLI
# ---------------------------------------------------------------------------
#
# Contract (``ExternalCliContractSchemaV1``). The store invokes the program
# with EXACTLY two verbs:
#
#   * ``PROG put <KEY>`` — the request JSON object is written to the child's
#     STDIN:
#       {"schema":"reprobuild.lockstore.external-cli.v1",
#        "op":"put","key":"<KEY>","value":"<BASE64>"}
#     ``<BASE64>`` is standard base64 of the value bytes (a framed record or
#     an evidence envelope). The child persists value-by-key and exits 0 on
#     success (non-zero ⇒ the store reports ``spoFailed``).
#
#   * ``PROG get <KEY>`` — no stdin. The child writes a JSON object to STDOUT:
#       hit:  {"schema":"...","found":true,"value":"<BASE64>"}   exit 0
#       miss: {"schema":"...","found":false}                     exit 0 or 3
#     Any other non-zero exit ⇒ a read error (treated as a miss by the
#     resolver but logged).
#
# Keys: ``lock/<project>/<repo>/<sha>`` (the record), ``latest/<project>/
# <repo>`` and ``latest-any/<project>`` (pointers whose value is the full
# framed record, so a read is a single get), and ``evidence/<project>/
# <repo>``. Base64 keeps every value free of quotes/newlines so even a
# trivial shell-script DB can extract it.

type
  ExternalCliLockStore* = ref object of LockStore
    program*: string
      ## Absolute path of the external store program.

proc newExternalCliLockStore*(program: string): ExternalCliLockStore =
  ExternalCliLockStore(program: absolutePath(program))

method backendId*(s: ExternalCliLockStore): string = "external-cli"

method storeLocationLabel*(s: ExternalCliLockStore): string = s.program

proc ecPutRaw(s: ExternalCliLockStore; key, value: string): StorePutResult =
  let request = $(%*{
    "schema": ExternalCliContractSchemaV1,
    "op": "put", "key": key, "value": base64.encode(value)})
  var p = startProcess(s.program, args = @["put", key],
    options = {poUsePath})
  p.inputStream.write(request)
  p.inputStream.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    return failed("external-cli put '" & key & "' exited " & $code &
      ": " & output.strip())
  ok()

proc ecGetRaw(s: ExternalCliLockStore; key: string): Option[string] =
  var p = startProcess(s.program, args = @["get", key], options = {poUsePath})
  p.inputStream.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code == 3: return none(string)
  if code != 0: return none(string)
  var node: JsonNode
  try:
    node = parseJson(output)
  except CatchableError:
    return none(string)
  if node.kind != JObject or not node.hasKey("found"): return none(string)
  if not node["found"].getBool(): return none(string)
  if not node.hasKey("value"): return none(string)
  some(base64.decode(node["value"].getStr()))

proc ecKeyRecord(k: StoreLockKey): string =
  "lock/" & k.project & "/" & k.repo & "/" & k.sha
proc ecKeyLatest(project, repo: string): string =
  "latest/" & project & "/" & repo
proc ecKeyLatestAny(project: string): string =
  "latest-any/" & project
proc ecKeyEvidence(project, repo: string): string =
  "evidence/" & project & "/" & repo

method putLock*(s: ExternalCliLockStore;
    rec: StoreLockRecord): StorePutResult =
  let blob = encodeRecord(rec)
  for key in [ecKeyRecord(rec.key), ecKeyLatest(rec.key.project, rec.key.repo),
              ecKeyLatestAny(rec.key.project)]:
    let r = ecPutRaw(s, key, blob)
    if r.outcome != spoOk: return r
  ok()

method latestLock*(s: ExternalCliLockStore; project, repo: string):
    Option[StoreLockRecord] =
  let v = ecGetRaw(s, ecKeyLatest(project, repo))
  if v.isNone: return none(StoreLockRecord)
  some(decodeRecord(v.get()))

method latestLockAny*(s: ExternalCliLockStore; project: string):
    Option[StoreLockRecord] =
  let v = ecGetRaw(s, ecKeyLatestAny(project))
  if v.isNone: return none(StoreLockRecord)
  some(decodeRecord(v.get()))

method putEvidence*(s: ExternalCliLockStore; project, repo: string;
    ev: seq[WorkspaceVcsEvidence]): StorePutResult =
  ecPutRaw(s, ecKeyEvidence(project, repo), encodeEvidenceBlob(ev))

method getEvidence*(s: ExternalCliLockStore; project, repo: string):
    seq[WorkspaceVcsEvidence] =
  let v = ecGetRaw(s, ecKeyEvidence(project, repo))
  if v.isNone: return @[]
  decodeEvidenceBlob(v.get())
