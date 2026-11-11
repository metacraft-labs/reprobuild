## reprobuild/docs/users -- one-shot server-side render of a route, for a quick
## check without the static build: `just serve-docs`.

when defined(js):
  {.error: "ssr.nim is a C-target (server-side) entry point".}

import "../../../../isonim-docs/src/ssr" as frameworkSsr
import ./docs_config

proc renderRoute*(path: string; contentDir = "content"): tuple[status: int, html: string] =
  frameworkSsr.renderRoute(path, contentDir, cfg = reprobuildDocsConfig())

when isMainModule:
  let (status, html) = renderRoute("/")
  echo "SSR smoke: GET / -> ", status, " (", html.len, " bytes)"
