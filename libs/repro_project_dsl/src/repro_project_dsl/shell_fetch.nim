## Shell fragments shared by source-fetch action emitters.

import std/strutils

const
  CurlFetchRetryArgs* =
    "--retry 5 --retry-delay 2 --retry-max-time 300 --retry-all-errors " &
    "--connect-timeout 30 --max-time 300"

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
