## reprobuild/docs/users -- the reference gate: `just check-links`.
##
## Fails, naming file and line, on any internal link that points at no page, any
## `#anchor` that names no heading, and any two pages that claim one route. It
## runs the framework's `validateContentGraph` over this site's own content.

when defined(js):
  {.error: "check_links.nim is a C-target entry point".}

import core/routes
import core/references

when isMainModule:
  const contentDir = "content"
  try:
    validateContentGraph(contentDir, buildManifestFromContent(contentDir))
    echo "docs references: OK"
  except BrokenReferenceError as e:
    stderr.writeLine(e.msg)
    quit(1)
