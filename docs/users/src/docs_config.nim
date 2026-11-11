## reprobuild/docs/users -- this site's own `DocsConfig`.
##
## The reprobuild documentation, built with the isonim-docs framework and
## themed with the shared Metacraft docs theme (`theme_tokens.nim`), following
## isonim/docs/users and codetracer/docs/book-isonim.
##
## The site is a preview: its pages still carry claims that no check verifies
## yet, listed in each page's `unverified:` front matter. The footer states how
## many there are. The number is counted from the content at build time
## (`countUnverifiedClaims`), never typed, so it cannot drift from the pages.

import std/strutils
import core/config
import core/base_path

const docsSiteOrigin* = "https://docs.reprobuild.com"
  ## The canonical origin the sitemap, robots.txt and canonical links are
  ## built against.

const repositoryUrl* = "https://github.com/metacraft-labs/reprobuild"
const contentSourceUrl* = repositoryUrl & "/tree/agents/docs/users/content"

proc countUnverifiedClaims*(pageSource: string): int =
  ## The number of `unverified:` entries in one page's front matter: lines of
  ## the form `  - claim: ...` between the opening and closing `---`.
  let lines = pageSource.splitLines()
  if lines.len == 0 or lines[0].strip() != "---":
    return 0
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.strip() == "---":
      break
    if line.startsWith("  - claim:"):
      inc result

proc previewFooterHtml*(unverifiedClaims, pages: int): string =
  ## The footer of every page: a statement that this is a preview, with the
  ## debt register's size, and a link to the sources that list each claim.
  "Preview documentation for reprobuild. " & $unverifiedClaims &
    " statements across " & $pages & " pages are not yet backed by a check; " &
    "each page lists its own in its <a href=\"" & contentSourceUrl &
    "\">source</a>. " &
    "Built by <a href=\"https://github.com/metacraft-labs\">Metacraft Labs</a>."

proc reprobuildDocsConfig*(basePath = ""; footerHtml = ""): DocsConfig =
  ## This site's `DocsConfig`. `basePath` is the URL prefix the build is hosted
  ## under (`""` for the site root); `footerHtml` is the rendered footer, which
  ## `build.nim` computes from the content.
  let base = normalizeBasePath(basePath)
  DocsConfig(
    siteTitle: "Reprobuild",
    siteDescription: "Documentation for reprobuild (repro): builds, " &
      "development environments, tasks, services and multi-repository " &
      "workspaces from one description of each project.",
    defaultRoute: "/",
    stylesheetHref: "/assets/style.css",
    baseUrl: docsSiteOrigin & base,
    basePath: base,
    # The documentation's top-level sections in reading order; anything not
    # listed would otherwise sort alphabetically.
    sectionOrder: @["tutorials", "guides", "concepts", "coming-from", "reference"],
    headerLinks: @[
      (label: "Install", href: "/install"),
      (label: "GitHub", href: repositoryUrl),
    ],
    sidebarLinks: @[
      (label: "GitHub", href: repositoryUrl, icon: "/assets/img/icon__github.svg"),
    ],
    # A monochrome wordmark: the theme inverts the logo on the dark canvas.
    siteLogo: "/assets/img/reprobuild-wordmark.svg",
    logoHref: "/",
    sidebarThemeToggle: true,
    pageTitleInContent: true,
    # Ship the client bundle (src/main.nim) on every page so that search, the
    # theme toggle and sidebar collapse work; the pages stay readable without it.
    appScriptHref: defaultAppScriptUrl,
    expandAllNavSections: true,
    footerHtml: footerHtml,
  )
