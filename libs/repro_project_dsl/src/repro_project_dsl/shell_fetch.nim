## Shell fragments shared by source-fetch action emitters.

import std/strutils

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
