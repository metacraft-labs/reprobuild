## reprobuild/docs/users -- the static-site build entry.
##
## Builds `content/` into `public/` with the isonim-docs scaffold: the SSG pass,
## the shared Metacraft docs token CSS prepended onto the stylesheet, the client
## bundle compiled from `src/main.nim`, and `static/` copied into
## `public/assets/`.
##
## Before the SSG pass the pages are staged into `build/content/` with every
## `{{ name }}` placeholder replaced by its value, because the framework has no
## interpolation of its own. A value has exactly one source:
##
## - `repro.version`: the `version` declared in `reprobuild.nimble`;
## - any other name: the `[values]` table of a scenario in `scenarios/`, which
##   is where the scenario that checks the page pins it.
##
## A placeholder with no value stops the build, so a page can never be
## published with a literal `{{ ... }}` in it.
##
## `REPRO_DOCS_BASE_PATH` sets the URL prefix the build is hosted under (empty
## for the site root).

when defined(js):
  {.error: "build.nim is a C-target (SSG) entry; not for the JS target".}

import std/[os, strutils, tables]
import docs_scaffold
import ./docs_config
import ./theme_tokens

const
  basePathEnvVar* = "REPRO_DOCS_BASE_PATH"
  nimblePath = "../../reprobuild.nimble"
  scenariosDir = "scenarios"
  sourceDir = "content"
  stagedDir = "build/content"

proc unquote(value: string): string =
  result = value.strip()
  if result.len >= 2 and result[0] == '"' and result[^1] == '"':
    result = result[1 .. ^2]

proc declaredVersion(path: string): string =
  ## The `version = "x.y.z"` line of a nimble file.
  for line in readFile(path).splitLines():
    let parts = line.split('=', maxsplit = 1)
    if parts.len == 2 and parts[0].strip() == "version":
      return unquote(parts[1])
  quit("docs build: no version line in " & path, 1)

proc scenarioValues(dir: string): Table[string, string] =
  ## Every `"name" = "value"` line in the `[values]` table of each scenario.
  for path in walkFiles(dir / "*.toml"):
    var inValues = false
    for raw in readFile(path).splitLines():
      let line = raw.strip()
      if line.startsWith("["):
        inValues = line == "[values]"
      elif inValues and '=' in line and not line.startsWith("#"):
        let parts = line.split('=', maxsplit = 1)
        result[unquote(parts[0])] = unquote(parts[1])

proc interpolate(text, path: string; values: Table[string, string]): string =
  ## `text` with each `{{ name }}` replaced; an unknown name is fatal.
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    let open = text.find("{{", i)
    if open < 0:
      result.add text[i .. ^1]
      break
    let close = text.find("}}", open + 2)
    if close < 0:
      quit("docs build: unclosed {{ in " & path, 1)
    let name = text[open + 2 ..< close].strip()
    if name notin values:
      quit("docs build: " & path & " uses {{ " & name &
           " }}, which has no value (declare it in a scenario's [values])", 1)
    result.add text[i ..< open]
    result.add values[name]
    i = close + 2

proc stageContent(src, dst: string; values: Table[string, string]):
    tuple[claims, pages: int] =
  ## Copy `src` to `dst` with placeholders filled in, counting pages and their
  ## `unverified:` claims on the way.
  removeDir(dst)
  for path in walkDirRec(src):
    let rel = relativePath(path, src)
    let target = dst / rel
    createDir(target.parentDir)
    if path.endsWith(".md"):
      let text = readFile(path)
      inc result.pages
      result.claims += countUnverifiedClaims(text)
      writeFile(target, interpolate(text, path, values))
    else:
      copyFile(path, target)

when isMainModule:
  var values = scenarioValues(scenariosDir)
  values["repro.version"] = declaredVersion(nimblePath)
  let stats = stageContent(sourceDir, stagedDir, values)
  let cfg = reprobuildDocsConfig(getEnv(basePathEnvVar),
                                 previewFooterHtml(stats.claims, stats.pages))
  let n = buildDocsSite(cfg,
                        contentDir = stagedDir,
                        docsTokensCss = metacraftDocsTokensCss(),
                        clientEntry = "src/main.nim")
  echo "SSG: rendered ", n, " static pages into ./public/ (",
    stats.claims, " unverified claims across ", stats.pages, " pages; ",
    "repro.version = ", values["repro.version"], ")"
