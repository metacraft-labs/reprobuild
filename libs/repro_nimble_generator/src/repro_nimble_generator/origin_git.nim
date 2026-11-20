## Git as the generator's origin transport, bounded and confined.
##
## The `refs`, `source` and history edges run `git` against an origin that
## passed the egress policy (`egress.vetOrigin`). Every invocation:
##
## * runs the resolved git binary by its absolute path, with an argv and no
##   shell, in an environment built from nothing (no `GIT_*`, proxy, token
##   or credential variable of the host reaches it; `HOME` is scratch; the
##   system and global configuration are not read);
## * allows the `https` transport only (`protocol.allow=never`,
##   `protocol.https.allow=always`, `GIT_ALLOW_PROTOCOL=https`), never
##   follows a redirect itself (`http.followRedirects=false`), is pinned to
##   the vetted addresses (`http.curloptResolve`), answers no credential
##   prompt, never recurses into submodules and never starts background
##   maintenance;
## * is bounded: the bytes it transfers and stores (`maxBytes`, checked on
##   its output and on the size of the repository it writes), the time
##   without progress (`stallSeconds`) and the wall time (`wallSeconds`).
##   Exceeding one kills the child (this process's own child, by its pid) and
##   is an egress refusal (`erSize`, `erStall`, `erTimeout`).
##
## Trees are read from git objects (`ls-tree`, `cat-file`), never from a
## checkout: nothing is materialized, so a symbolic link in a package can
## never be followed (threat model G4).

import std/[algorithm, os, osproc, streams, strtabs, strutils, tables, times]
when defined(posix):
  import std/posix

import repro_core/ambient_execution
import repro_core/process_close

import ./egress

type
  GitRun* = object
    code*: int
    stdoutText*: string
    stderrText*: string

  OriginGit* = object
    ## How the generator runs git: the binary, and the trust anchors.
    gitBin*: string
    caFile*: string

  LsRemote* = object
    headRef*: string ## `refs/heads/<x>` without the prefix, or ""
    head*: string
    tags*: seq[(string, string)] ## (name, peeled object), sorted by name
    branches*: seq[(string, string)]

  TreeEntryKind* = enum
    teFile, teExecutable, teSymlink, teGitlink, teOther

  TreeEntry* = object
    kind*: TreeEntryKind
    mode*: string
    oid*: string
    path*: string ## relative to the package directory

  FetchedTree* = object
    commitTime*: int64
    entries*: seq[TreeEntry]      ## sorted by path
    blobs*: Table[string, string] ## oid -> bytes, for files and links

const
  BaseConfig = [
    "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
    "-c", "http.followRedirects=false", "-c", "http.sslVerify=true",
    "-c", "credential.helper=", "-c", "core.askPass=",
    "-c", "fetch.recurseSubmodules=false", "-c", "submodule.recurse=false",
    "-c", "maintenance.auto=false", "-c", "gc.auto=0",
    "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main",
    "-c", "advice.detachedHead=false", "-c", "core.fsmonitor=false"]

proc gitEnvironment*(g: OriginGit; home: string): StringTableRef =
  ## The child's whole environment. Nothing of this process's is passed.
  result = newStringTable(modeCaseSensitive)
  result["PATH"] = parentDir(g.gitBin)
  result["HOME"] = home
  result["XDG_CONFIG_HOME"] = home / ".config"
  result["GIT_CONFIG_NOSYSTEM"] = "1"
  result["GIT_CONFIG_GLOBAL"] = "/dev/null"
  result["GIT_TERMINAL_PROMPT"] = "0"
  result["GIT_ALLOW_PROTOCOL"] = "https"
  result["GIT_NO_LAZY_FETCH"] = "1"
  result["GIT_NO_REPLACE_OBJECTS"] = "1"
  result["LC_ALL"] = "C"
  result["LANG"] = "C"
  result["TZ"] = "UTC"
  if g.caFile.len > 0:
    result["GIT_SSL_CAINFO"] = g.caFile

proc treeBytes(dir: string): int64 =
  if dir.len == 0 or not dirExists(dir):
    return 0
  for path in walkDirRec(dir, yieldFilter = {pcFile}):
    try: result += getFileSize(path)
    except OSError: discard

proc runBounded*(g: OriginGit; args: seq[string]; cwd, home: string;
                 limits: EgressLimits; url = ""; watchDir = "";
                 input = ""): GitRun =
  ## Run git under the limits (see the module docstring). Raises
  ## `EgressError` when a limit is exceeded, after killing the child.
  when not defined(posix):
    refuse(erMalformed, url, "the generator's origin transport runs on " &
      "POSIX hosts only")
  else:
    createDir(home)
    var full = @BaseConfig
    for a in args: full.add a
    let p = uncontrolledStartProcess(g.gitBin, workingDir = cwd, args = full,
      env = gitEnvironment(g, home), options = {})
    var killed = false
    var refusal: EgressRefusal
    var refused = false
    try:
      let outFd = cint(p.outputHandle)
      let errFd = cint(p.errorHandle)
      let inFd = cint(p.inputHandle)
      for fd in [outFd, errFd, inFd]:
        let flags = fcntl(fd, F_GETFL)
        discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
      var inPos = 0
      var inOpen = true
      if input.len == 0:
        streams.close(p.inputStream)
        inOpen = false
      var outOpen = true
      var errOpen = true
      let start = epochTime()
      var lastProgress = start
      var lastSize = 0'i64
      var lastCheck = 0.0
      var buf: array[65536, char]
      while outOpen or errOpen:
        var pfds: array[3, TPollfd]
        pfds[0] = TPollfd(fd: (if outOpen: outFd else: -1), events: POLLIN)
        pfds[1] = TPollfd(fd: (if errOpen: errFd else: -1), events: POLLIN)
        pfds[2] = TPollfd(fd: (if inOpen: inFd else: -1), events: POLLOUT)
        let ready = posix.poll(addr pfds[0], Tnfds(3), 100)
        if ready < 0 and errno != EINTR:
          raiseOSError(osLastError())
        var progressed = false
        if ready > 0:
          for i in 0 .. 1:
            if pfds[i].revents != 0:
              let fd = if i == 0: outFd else: errFd
              let n = posix.read(fd, addr buf[0], buf.len)
              if n > 0:
                progressed = true
                if i == 0:
                  let at = result.stdoutText.len
                  result.stdoutText.setLen(at + n)
                  copyMem(addr result.stdoutText[at], addr buf[0], n)
                else:
                  if result.stderrText.len < 65536:
                    let at = result.stderrText.len
                    result.stderrText.setLen(at + n)
                    copyMem(addr result.stderrText[at], addr buf[0], n)
              elif n == 0 or (errno != EAGAIN and errno != EWOULDBLOCK):
                if i == 0: outOpen = false else: errOpen = false
          if inOpen and pfds[2].revents != 0:
            if (pfds[2].revents and POLLOUT) != 0 and inPos < input.len:
              let n = posix.write(inFd, unsafeAddr input[inPos],
                min(65536, input.len - inPos))
              if n > 0:
                inPos += n
                progressed = true
            if inPos >= input.len or (pfds[2].revents and (POLLERR or POLLHUP)) != 0:
              streams.close(p.inputStream)
              inOpen = false
        let now = epochTime()
        if now - lastCheck >= 0.2:
          lastCheck = now
          let size = result.stdoutText.len.int64 + treeBytes(watchDir)
          if size != lastSize:
            lastSize = size
            progressed = true
          if size > limits.maxBytes:
            refused = true
            refusal = EgressRefusal(kind: erSize, url: url,
              detail: "the transfer passed " & $limits.maxBytes & " bytes")
        if progressed:
          lastProgress = now
        if not refused and now - lastProgress > float(limits.stallSeconds):
          refused = true
          refusal = EgressRefusal(kind: erStall, url: url,
            detail: "no progress for " & $limits.stallSeconds & " s")
        if not refused and now - start > float(limits.wallSeconds):
          refused = true
          refusal = EgressRefusal(kind: erTimeout, url: url,
            detail: "the transfer took longer than " & $limits.wallSeconds &
              " s")
        if refused:
          p.kill()
          killed = true
          break
        if not outOpen and not errOpen:
          break
        if peekExitCode(p) != -1 and ready == 0:
          # Exited and nothing left queued: what a detached grandchild
          # writes later is not the child's output.
          break
      if inOpen:
        streams.close(p.inputStream)
      result.code = p.waitForExit()
      # A transfer that finished between two checks is still measured: the
      # limit is on what was received and stored, however fast it came.
      if not refused:
        let size = result.stdoutText.len.int64 + treeBytes(watchDir)
        if size > limits.maxBytes:
          refused = true
          refusal = EgressRefusal(kind: erSize, url: url,
            detail: "the transfer passed " & $limits.maxBytes & " bytes")
    finally:
      closeProcessOnce(p)
    if refused:
      var e = newException(EgressError, "origin refused (" & $refusal.kind &
        "): " & refusal.url & ": " & refusal.detail)
      e.refusal = refusal
      raise e
    discard killed

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

proc networkArgs(v: VettedOrigin; limits: EgressLimits): seq[string] =
  @["-c", "http.curloptResolve=" & curloptResolve(v),
    "-c", "http.lowSpeedLimit=1",
    # git's own stall limit is the backstop; the runner's, which is a
    # refusal, comes first.
    "-c", "http.lowSpeedTime=" & $(limits.stallSeconds + 5)]

proc isHexId(s: string): bool =
  s.len in [40, 64] and s.allCharsInSet({'0'..'9', 'a'..'f'})

proc lsRemote*(g: OriginGit; v: VettedOrigin; scratch: string;
               limits: EgressLimits): tuple[ok: bool; answer: LsRemote;
                 failure: string] =
  ## The origin's refs, tags peeled (`<tag>^{}`), and its `HEAD`.
  createDir(scratch)
  var args = networkArgs(v, limits)
  args.add ["ls-remote", "--symref", baseUrl(v.final)]
  let r = runBounded(g, args, scratch, scratch / "home", limits,
    url = baseUrl(v.final))
  if r.code != 0:
    return (false, LsRemote(), r.stderrText.strip().splitLines().join(" | "))
  var direct = initTable[string, string]()
  var peeled = initTable[string, string]()
  for line in r.stdoutText.splitLines():
    if line.len == 0: continue
    if line.startsWith("ref: "):
      let parts = line["ref: ".len .. ^1].split('\t')
      if parts.len == 2 and parts[1] == "HEAD" and
          parts[0].startsWith("refs/heads/"):
        result.answer.headRef = parts[0]["refs/heads/".len .. ^1]
      continue
    let parts = line.split('\t')
    if parts.len != 2 or not isHexId(parts[0]):
      continue
    let (oid, name) = (parts[0], parts[1])
    if name == "HEAD":
      result.answer.head = oid
    elif name.startsWith("refs/tags/"):
      let t = name["refs/tags/".len .. ^1]
      if t.endsWith("^{}"):
        peeled[t[0 ..< t.len - 3]] = oid
      else:
        direct[t] = oid
    elif name.startsWith("refs/heads/"):
      result.answer.branches.add (name["refs/heads/".len .. ^1], oid)
  for t, oid in direct:
    result.answer.tags.add (t, peeled.getOrDefault(t, oid))
  result.answer.tags.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  result.answer.branches.sort(proc (a, b: (string, string)): int =
    cmp(a[0], b[0]))
  result.ok = true

proc localGit(g: OriginGit; repo: string; args: openArray[string];
              limits: EgressLimits; input = ""): GitRun =
  var full = @["--git-dir=" & repo]
  for a in args: full.add a
  runBounded(g, full, repo, parentDir(repo) / "home", limits, input = input)

proc fetchCommit*(g: OriginGit; v: VettedOrigin; scratch, commit: string;
                  limits: EgressLimits): tuple[ok: bool; repo, failure: string] =
  ## Fetch exactly ``commit`` (depth 1) into a fresh bare repository.
  let repo = scratch / "repo.git"
  createDir(scratch)
  let init = runBounded(g, @["init", "--bare", "-q", repo], scratch,
    scratch / "home", limits)
  if init.code != 0:
    return (false, "", "git init failed: " & init.stderrText.strip())
  var args = @["--git-dir=" & repo]
  args.add networkArgs(v, limits)
  args.add ["fetch", "--no-tags", "--no-write-fetch-head", "--depth=1",
    "--no-auto-maintenance", baseUrl(v.final), commit]
  let r = runBounded(g, args, scratch, scratch / "home", limits,
    url = baseUrl(v.final), watchDir = repo)
  if r.code != 0:
    return (false, repo, r.stderrText.strip().splitLines().join(" | "))
  let t = localGit(g, repo, ["cat-file", "-t", commit], limits)
  if t.code != 0 or t.stdoutText.strip() != "commit":
    return (false, repo, "not-a-commit: " & commit & " is a " &
      t.stdoutText.strip())
  (true, repo, "")

proc readTree*(g: OriginGit; repo, commit, subdir: string;
               limits: EgressLimits): FetchedTree =
  ## Every entry of ``commit``'s tree under ``subdir``, and the bytes of its
  ## files and links, read from objects. Raises `EgressError` (`erSize`)
  ## when the contents pass the byte limit.
  let ct = localGit(g, repo, ["show", "-s", "--format=%ct", commit], limits)
  if ct.code == 0:
    try: result.commitTime = parseBiggestInt(ct.stdoutText.strip())
    except ValueError: discard
  var args = @["ls-tree", "-r", "-z", "--full-tree", commit]
  let prefix = if subdir.len > 0: subdir.strip(chars = {'/'}) & "/" else: ""
  let r = localGit(g, repo, args, limits)
  if r.code != 0:
    raise newException(IOError, "ls-tree failed: " & r.stderrText.strip())
  var wanted: seq[string]
  for rec in r.stdoutText.split('\0'):
    if rec.len == 0: continue
    let tab = rec.find('\t')
    if tab < 0: continue
    let meta = rec[0 ..< tab].split(' ')
    var path = rec[tab + 1 .. ^1]
    if meta.len != 3: continue
    if prefix.len > 0:
      if not path.startsWith(prefix): continue
      path = path[prefix.len .. ^1]
    let kind =
      case meta[0]
      of "100644": teFile
      of "100755": teExecutable
      of "120000": teSymlink
      of "160000": teGitlink
      else: teOther
    result.entries.add TreeEntry(kind: kind, mode: meta[0], oid: meta[2],
      path: path)
    if kind in {teFile, teExecutable, teSymlink}:
      wanted.add meta[2]
  result.entries.sort(proc (a, b: TreeEntry): int = cmp(a.path, b.path))
  if wanted.len == 0:
    return
  var input = ""
  var seen = initTable[string, bool]()
  for oid in wanted:
    if oid notin seen:
      seen[oid] = true
      input.add oid & "\n"
  let b = localGit(g, repo, ["cat-file", "--batch"], limits, input = input)
  if b.code != 0:
    raise newException(IOError, "cat-file failed: " & b.stderrText.strip())
  var pos = 0
  let s = b.stdoutText
  while pos < s.len:
    let nl = s.find('\n', pos)
    if nl < 0: break
    let header = s[pos ..< nl].split(' ')
    pos = nl + 1
    if header.len == 2 and header[1] == "missing":
      continue
    if header.len != 3: break
    let size = parseInt(header[2])
    if pos + size > s.len: break
    result.blobs[header[0]] = s[pos ..< pos + size]
    pos += size + 1

proc fetchHistory*(g: OriginGit; v: VettedOrigin; scratch: string;
                   limits: EgressLimits): tuple[ok: bool;
                     branchCommits, allCommits: seq[string]; failure: string] =
  ## The commits of every branch and tag of the origin (commits only; trees
  ## and blobs are filtered out where the origin supports it).
  let repo = scratch / "history.git"
  createDir(scratch)
  let init = runBounded(g, @["init", "--bare", "-q", repo], scratch,
    scratch / "home", limits)
  if init.code != 0:
    return (false, @[], @[], "git init failed")
  var args = @["--git-dir=" & repo]
  args.add networkArgs(v, limits)
  args.add ["fetch", "--no-tags", "--no-write-fetch-head", "--filter=tree:0",
    "--no-auto-maintenance", baseUrl(v.final),
    "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]
  let r = runBounded(g, args, scratch, scratch / "home", limits,
    url = baseUrl(v.final), watchDir = repo)
  if r.code != 0:
    return (false, @[], @[], r.stderrText.strip().splitLines().join(" | "))
  let br = localGit(g, repo, ["rev-list", "--branches"], limits)
  let al = localGit(g, repo, ["rev-list", "--all"], limits)
  if br.code != 0 or al.code != 0:
    return (false, @[], @[], "rev-list failed")
  for l in br.stdoutText.splitLines():
    if isHexId(l): result.branchCommits.add l
  for l in al.stdoutText.splitLines():
    if isHexId(l): result.allCommits.add l
  result.branchCommits.sort()
  result.allCommits.sort()
  result.ok = true
