## Report-only forge identity discovery. Git redirects intentionally remain
## usable; the manifest owner decides whether and how to record a rename.
import std/[json, monotimes, os, osproc, strutils, streams, tables, times]
import repro_core/ambient_execution
import repro_workspace_manifests
import shared_clones

type
  IdentityAnswer = tuple[canonical, reason: string, stop: bool]
  RepositoryIdentityCache* = ref object
    ## Invocation-scoped, including health's post-fix second gathering pass.
    answers: Table[string, IdentityAnswer]
    stopped: bool
  RepositoryIdentityReport* = object
    findings*: seq[string]
    remedies*: seq[string]
    repos*: JsonNode
    checked*, skipped*: int
    unavailable*, unsupported*: bool

proc validGithubIdentity(value: string): bool =
  ## Only literal owner/repository components are accepted as an API endpoint.
  ## In particular no query, fragment, escapes or control characters can turn
  ## a declared URL or unexpected response into another request or terminal text.
  let parts = value.split('/')
  if parts.len != 2: return false
  for part in parts:
    if part.len == 0 or part in [".", ".."]: return false
    for ch in part:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}: return false
  true

proc githubIdentity(url: string): tuple[local: bool, identity: string] =
  let lower = url.toLowerAscii
  # Git accepts host:path without a user as SCP syntax. Adapt only this
  # observation; changing the shared pool's URL normalization would re-key it.
  let normalized = if lower.startsWith("github.com:"): "git@" & url else: url
  let windowsPath = url.len >= 3 and url[0] in {'a'..'z', 'A'..'Z'} and
    url[1] == ':' and url[2] in {'/', '\\'}
  # Explicit local path syntax wins over punctuation resembling SCP. Git
  # requires ./ for an otherwise ambiguous relative path containing a colon.
  if windowsPath or url.startsWith("/") or url.startsWith("./") or
      url.startsWith("../") or url.startsWith("~/") or url.startsWith("\\\\"):
    result.local = true
    return
  let network = lower.startsWith("https://") or lower.startsWith("http://") or
    lower.startsWith("ssh://") or lower.startsWith("git://") or
    (not normalized.contains("://") and normalized.contains('@') and normalized.contains(':'))
  if not network:
    result.local = windowsPath or (not url.contains("://") and not url.contains(':')) or lower.startsWith("file://")
    return
  # Reuse the pool's credential-free authority/default-port normalization.
  # Its path case remains intact; GitHub comparison below folds case only
  # after the host has been identified as the public GitHub endpoint.
  let identity = canonicalRemoteIdentity(normalized)
  if identity.startsWith("github.com/"):
    let path = identity["github.com/".len .. ^1]
    if validGithubIdentity(path): result.identity = path

proc queryGithub(gh, identity: string): tuple[canonical, reason: string, stop: bool] =
  ## gh is deliberately ambient: use the operator's established forge auth.
  ## Do not merge stderr (it can contain credentials) or pass a fetch URL.
  ## Waiting before reading is safe for the tiny expected full_name response;
  ## oversized/malicious responses fill the pipe and hit the same deadline.
  var child: Process
  try:
    child = uncontrolledStartProcess(gh, args = @["api", "--hostname",
      "github.com", "repos/" & identity, "--jq", ".full_name"], options = {})
    defer: child.close()
    # osproc.waitForExit(timeout) kills on POSIX and returns the signal exit
    # status, not a distinct timeout result. Own the deadline so a timed-out
    # forge cannot be confused with an ordinary API refusal, and suppress the
    # rest of this invocation's probes after losing connectivity.
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while child.peekExitCode() == -1 and getMonoTime() < deadline:
      sleep(10)
    if child.peekExitCode() == -1:
      child.kill()
      discard child.waitForExit()
      return ("", "API query timed out", true)
    let code = child.waitForExit()
    if code != 0: return ("", "API unavailable (network, authentication or repository access)", false)
    let response = child.outputStream.readAll().strip()
    if not validGithubIdentity(response):
      return ("", "API returned an invalid canonical identity", false)
    return (response, "", false)
  except CatchableError:
    return ("", "could not start API client", true)

proc newRepositoryIdentityCache*(): RepositoryIdentityCache =
  ## Explicit invocation ownership prevents cached forge answers leaking into
  ## later health commands run by an embedding caller.
  RepositoryIdentityCache(answers: initTable[string, IdentityAnswer]())

proc inspectRepositoryIdentities*(repos: seq[ResolvedRepo]; offline: bool;
    cache: RepositoryIdentityCache): RepositoryIdentityReport =
  ## One observation per participating repo, even when several declarations
  ## share an API query or a preceding timeout has prevented further probes.
  result.repos = newJArray()
  let gh = if offline: "" else: uncontrolledFindExe("gh")
  for repo in repos:
    let declared = githubIdentity(repo.fetchUrl)
    var canonical, reason, outcome: string
    if declared.local:
      outcome = "local"
      reason = "local path; no forge identity to check"
      inc result.skipped
    elif declared.identity.len == 0:
      outcome = "unconfirmed"
      result.unsupported = true
      reason = "unsupported forge URL or port; not checked"
      inc result.skipped
    else:
      if offline:
        reason = "offline; not checked"
      elif gh.len == 0:
        reason = "gh unavailable; not checked"
      elif cache.answers.hasKey(declared.identity.toLowerAscii):
        let previous = cache.answers[declared.identity.toLowerAscii]
        canonical = previous.canonical
        reason = previous.reason
      elif cache.stopped:
        reason = "not checked after API timeout or client failure"
      else:
        let answer = queryGithub(gh, declared.identity)
        cache.answers[declared.identity.toLowerAscii] = answer
        canonical = answer.canonical
        reason = answer.reason
        cache.stopped = answer.stop
      if canonical.len == 0:
        result.unavailable = true
        outcome = "unconfirmed"
        inc result.skipped
      else:
        inc result.checked
        outcome = if canonical.toLowerAscii == declared.identity.toLowerAscii: "equal" else: "mismatch"
    result.repos.add(%*{"repo": repo.name, "declared": declared.identity,
      "canonical": canonical, "outcome": outcome, "reason": reason})
    if outcome == "mismatch":
      result.findings.add(repo.name & ": declared " & declared.identity & " resolves to " & canonical)
      result.remedies.add("For " & repo.name & ", update the declaration's URL composition to " &
        canonical & "; if changing its manifest name or checkout path, preserve the old identity with " &
        "[extensions] previously = [{ name = " & $(%repo.name) & ", path = " & $(%repo.path) & " }]")
    elif outcome == "unconfirmed":
      result.findings.add(repo.name & ": " & (if declared.identity.len > 0: declared.identity & ": " else: "") &
        "unconfirmed (" & reason & ")")
  if result.unavailable:
    result.remedies.add("Install/authenticate gh (gh auth login --hostname github.com), restore connectivity and rerun repro health online")
  if result.unsupported:
    result.remedies.add("Inspect unsupported forge URLs manually; this check only queries the public github.com API")
