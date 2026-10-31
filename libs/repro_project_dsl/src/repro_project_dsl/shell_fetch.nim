## Shell fragments shared by source-fetch action emitters.

import std/strutils
import blake3

const
  CurlFetchRetryArgs* =
    "--retry 5 --retry-delay 2 --retry-max-time 300 --retry-all-errors " &
    "--connect-timeout 30 --max-time 300"

proc archiveDecompressorTool(archiveUrl: string): string =
  var normalized = archiveUrl.toLowerAscii()
  for marker in ['?', '#']:
    let markerPos = normalized.find(marker)
    if markerPos >= 0:
      normalized.setLen(markerPos)
  if normalized.endsWith(".tar.xz") or normalized.endsWith(".txz") or
      normalized.endsWith(".tar.lzma"):
    return "xz"
  if normalized.endsWith(".tar.gz") or normalized.endsWith(".tgz"):
    return "gzip"
  if normalized.endsWith(".tar.bz2") or normalized.endsWith(".tbz2") or
      normalized.endsWith(".tbz"):
    return "bzip2"
  if normalized.endsWith(".tar.zst") or normalized.endsWith(".tzst"):
    return "zstd"

proc isCommitId*(revision: string): bool =
  ## A full 40-hex SHA-1 object id (the only revision spelling that is not
  ## a ref); a ``fetch:`` block's ``gitRevision`` may be this or a tag /
  ## branch name, and the two are fetched differently (``git clone
  ## --branch`` cannot name a commit).
  if revision.len != 40: return false
  for ch in revision:
    if ch notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}: return false
  true

proc gitArchiveFetchScript*(escapedUrl, escapedRev, escapedTarball: string):
    string =
  ## The shell that acquires a git source as a tarball: clone (or, for a
  ## commit id, fetch exactly that object -- GitHub and every git since 2.5
  ## serve a reachable commit by id -- which is also the one form that pins
  ## a PRIVATE repository's revision without a tag) and ``git archive`` it.
  ## Shared by every emitter that handles ``dfkGitArchive`` so the two
  ## spellings are decided in one place.
  # Like `appendCurlDownload`: an archive already on disk is not taken
  # again. The digest check that follows this script still verifies it, so
  # a stale or truncated archive is refused rather than trusted; what is
  # skipped is only the network round trip -- which for a private
  # repository is also an ssh credential the fetch edge may not have on a
  # re-run that nothing else needed it for (ReproOS-Add-On-Mode A15).
  result = "if [ ! -f \"" & escapedTarball & "\" ]; then "
  result.add("rm -rf \"" & escapedTarball & ".git\"; ")
  if isCommitId(escapedRev):
    result.add("git init -q \"" & escapedTarball & ".git\"; ")
    result.add("git -C \"" & escapedTarball & ".git\" remote add origin \"" &
      escapedUrl & "\"; ")
    result.add("git -C \"" & escapedTarball & ".git\" fetch -q --depth 1 origin \"" &
      escapedRev & "\"; ")
    result.add("git -C \"" & escapedTarball & ".git\" checkout -q FETCH_HEAD; ")
  else:
    result.add("git clone --depth 1 ")
    if escapedRev.len > 0:
      result.add("--branch \"" & escapedRev & "\" ")
    result.add("\"" & escapedUrl & "\" \"" & escapedTarball & ".git\"; ")
  result.add("(cd \"" & escapedTarball & ".git\" && git archive --format=tar HEAD > \"" &
    escapedTarball & "\"); fi; ")

proc shellFetchToolIdentityRefs*(hashTools: openArray[string];
                                 copiesDataFile = false;
                                 archiveUrl = ""): seq[string] =
  ## Keep the execution profile aligned with every external command emitted
  ## by ``appendCurlDownload`` and ``appendTarExtraction``.
  result = @["sh", "rm", "mkdir", "curl", "mv"]
  for tool in hashTools:
    if tool.len > 0 and tool notin result:
      result.add(tool)
  if copiesDataFile:
    result.add("cp")
  else:
    result.add("tar")
    let decompressor = archiveDecompressorTool(archiveUrl)
    if decompressor.len > 0:
      result.add(decompressor)

proc shellDoubleQuote(value: string): string =
  value.replace("\\", "/").replace("\"", "\\\"")

proc shellFetchRuntimeEnv*(): seq[(string, string)] =
  ## Acquisition tools must use their own runtimes, not the fetched product's
  ## dependency libraries. Explicit action overrides survive auxiliary-path
  ## projection without changing PATH, linker inputs, or monitor injection.
  when defined(macosx):
    @[("LD_LIBRARY_PATH", ""), ("DYLD_LIBRARY_PATH", "")]
  elif defined(posix):
    @[("LD_LIBRARY_PATH", "")]
  else:
    @[]

proc appendCurlDownload*(script: var string; destination, url: string) =
  ## Download into a sibling temporary file and promote it only after curl
  ## succeeds. This keeps interrupted transfers from poisoning later runs.
  let escapedDestination = shellDoubleQuote(destination)
  let escapedPartial = shellDoubleQuote(destination & ".part")
  let escapedUrl = shellDoubleQuote(url)
  script.add("if [ ! -f \"" & escapedDestination & "\" ]; then ")
  script.add("rm -f \"" & escapedPartial & "\"; ")
  script.add("if curl -fsSL " & CurlFetchRetryArgs & " -o \"" &
    escapedPartial & "\" \"" & escapedUrl & "\" && [ -s \"" &
    escapedPartial & "\" ]; then ")
  script.add("mv -f \"" & escapedPartial & "\" \"" &
    escapedDestination & "\"; ")
  script.add("else rc=$?; rm -f \"" & escapedPartial &
    "\"; exit $rc; fi; fi; ")

proc appendTarExtraction*(script: var string; archive, destination: string;
                          stripComponents: int) =
  ## Extract a verified source archive into an existing staging directory.
  ## Windows tar implementations may materialize symlinks as target files;
  ## retrying after the other members exist resolves forward references.
  let escapedArchive = shellDoubleQuote(archive)
  let escapedDestination = shellDoubleQuote(destination)
  let forceLocal = when defined(windows): "--force-local " else: ""
  let command = "tar " & forceLocal & "-xf \"" & escapedArchive &
    "\" -C \"" & escapedDestination & "\" --strip-components=" &
    $stripComponents
  when defined(windows):
    script.add("if ! " & command & "; then " & command & "; fi; ")
  else:
    script.add(command & "; ")

proc projectAnchorOf*(pathUnderRepro: string): string =
  ## The project root a `<project>/.repro/...` path lives under, or "".
  let s = pathUnderRepro.replace('\\', '/')
  let i = s.find("/.repro/")
  if i > 0: s[0 ..< i] else: ""

proc withoutProjectPath*(text, anchor: string): string =
  ## `text` with every spelling of `anchor` — either separator, and on
  ## Windows any case — replaced by `<project>`.
  ##
  ## For hashing a program into an up-to-date token. The token binds WHAT the
  ## program does; where the checkout happens to be is not part of that, and a
  ## token that hashed it made the action's static description differ between
  ## two checkouts of the same recipe — so no portable record could ever be
  ## shared between them (Cache-Scope P3.4). Text that merely names a path
  ## is rewritten by portable logicalization; a path inside a HASH is not
  ## reachable by it, so it has to be taken out before hashing.
  if anchor.len == 0:
    return text
  result = text
  for spelling in [anchor.replace('\\', '/'), anchor.replace('/', '\\')]:
    when defined(windows):
      var i = 0
      var built = ""
      let lower = result.toLowerAscii()
      let needle = spelling.toLowerAscii()
      while i < result.len:
        let hit = lower.find(needle, i)
        if hit < 0:
          built.add(result[i .. ^1])
          break
        built.add(result[i ..< hit])
        built.add("<project>")
        i = hit + needle.len
      result = built
    else:
      result = result.replace(spelling, "<project>")

proc appendVerifiedFetchStamp*(script: var string; stamp: string) =
  ## Called only after successful verification and extraction. Bind the whole
  ## acquisition program so changed extraction settings invalidate consumers,
  ## while repeated verification of the same source does not change its mtime.
  ## Fetch actions remain noncacheable: the stamp is not evidence that a
  ## previously extracted tree still exists or that acquisition was monitored.
  ##
  ## The program is hashed with the project's own path taken out
  ## (`withoutProjectPath`), so two checkouts of one recipe agree on it.
  let token = "repro-source-fetch-v1:" & blake3.toHex(blake3.digest(
    withoutProjectPath(script, projectAnchorOf(stamp))))
  let escapedStamp = shellDoubleQuote(stamp)
  script.add("if [ -f \"" & escapedStamp & "\" ] && { " &
    "IFS= read -r repro_fetch_stamp && " &
    "[ \"$repro_fetch_stamp\" = \"" & token & "\" ] && " &
    "! IFS= read -r repro_fetch_extra && [ -z \"$repro_fetch_extra\" ]; " &
    "} < \"" & escapedStamp & "\"; then :; else " &
    "printf '%s\\n' '" & token & "' > \"" & escapedStamp & "\"; fi")
