## reprobuild/docs/users -- production-parity preview server over `public/`.
##
## Runs the full `scripts/build_user_docs.sh build` pipeline (link validation,
## generated-region checks, version interpolation, static HTML export, and
## `/llms.txt` + `/llms-full.txt` staging), serves `public/` with clean URLs,
## and re-exports with WebSocket live reload whenever `content/`, `src/` or
## `scenarios/` changes.

when defined(js):
  {.error: "serve_public.nim is a C-target entry point".}

import std/[os, strutils]
import isonim/server/static_dist_dev_server

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8000
  let host =
    if paramCount() >= 2: paramStr(2)
    elif existsEnv("AH_DEV_HOST"): getEnv("AH_DEV_HOST")
    else: "127.0.0.1"
  staticDistDevServer(
    rebuildCommand = @["bash", "../../scripts/build_user_docs.sh", "build"],
    distDir = "public",
    watchRoots = @["content", "src", "scenarios"],
    watchExts = defaultWatchExts & @[".md", ".toml"],
    siteName = "reprobuild user docs",
    port = port,
    host = host)
