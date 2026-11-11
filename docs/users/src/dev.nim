## reprobuild/docs/users -- the live-reloading documentation server:
## `just dev-docs [port] [host]`. Serves `content/` with the themed assets and
## reloads every open tab when a page changes.

import std/[os, strutils, asyncdispatch]
import docs_scaffold
import ./docs_config
import ./theme_tokens
export docs_scaffold

proc newDocsDevServer*(contentDir = "content";
                       assetsDirs = @["assets", "static"]): DevServer =
  docsDevServer(reprobuildDocsConfig(), contentDir = contentDir,
                assetsDirs = assetsDirs,
                tokensCssProvider = (proc(): string = docsTokensCssLive()),
                watchPaths = @[docsDesignSystemPath],
                clientEntry = "src/main.nim")

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8000
  # The host is the second argument, or loopback; pass 0.0.0.0 only on a
  # trusted network.
  let host = if paramCount() >= 2: paramStr(2) else: "127.0.0.1"
  let server = newDocsDevServer()
  stdout.writeLine "reprobuild docs dev server -> http://" & host & ":" & $port &
    "  (watching content/, live reload on; Ctrl-C to stop)"
  stdout.flushFile()
  waitFor serve(server, port, host = host)
