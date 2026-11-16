## reprobuild/docs/users -- the client bundle every page loads.
##
## Uses isonim-docs' shared `docs_client.mountStaticDocsClient` to wire live
## search (`/` and `Cmd/Ctrl+K` focus, `Escape` dismiss), dark/light theme
## toggle, `localStorage`-persisted sidebar collapse, `<768px` mobile drawer,
## `:::tabs` switching (click + arrow keys), and `Copy code` clipboard buttons.

when not defined(js):
  {.error: "main.nim requires the JS backend: nim js -o:app.js src/main.nim".}

import std/[os, tables]
import core/content
import core/content_embed
import core/routes
import core/search_vm
import docs_client

const embeddedContent = embedContentDir(currentSourcePath().parentDir() / "../content")

proc loadEmbeddedContentEntry(contentPath: string): ContentEntry =
  parseContentEntry(embeddedContent[contentPath], contentPath)

proc siteSearchIndex(): SearchIndex =
  var entries: seq[ContentEntry] = @[]
  for contentPath, raw in embeddedContent:
    let entry = parseContentEntry(raw, contentPath)
    if not entry.front.draft:
      entries.add entry
  sortContentEntries(entries)
  buildSearchIndex(buildManifestFromEntries(entries), loadEmbeddedContentEntry)

when isMainModule:
  mountStaticDocsClient(siteSearchIndex())
