## M59 gate: `e2e_generated_config_file_block_macro`.
##
## Normative description:
##
##   Generates a TOML file from a `tomlContent:` block reading three
##   configurables; first build writes the file; second build is a cache
##   hit; editing an unrelated configurable does not invalidate; editing
##   a read configurable rebuilds; output bytes are deterministic across
##   re-runs.
##
## Drives the M59 apply layer directly:
##   - `tomlContent:` block macro -> `RenderedContent`
##   - `configFile(state, store, scope, path, rendered)` -> apply result
##   - `state` is the in-memory cache-key store (one ApplyState per
##     fixture project).
## The M56 CAS lives under `<tmp>/store/`.

import std/[os, random, strutils, unittest]

import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/generated_config
import repro_local_store

proc setupScope(tmpRoot: string): HomeScope =
  putEnv("REPRO_HOME_PROFILE_TARGET", tmpRoot)
  result = resolveHomeScope()

proc setupStore(tmpRoot: string): Store =
  result = openStore(tmpRoot / "store")

proc render(ctx: ConfigContext;
            port, replicas: Configurable[int];
            host: Configurable[string]): RenderedContent =
  tomlContent(ctx):
    http:
      port = port
      host = host
    workers:
      count = replicas

suite "M59 block-macro gate":

  test "first build writes; second is a cache hit; output is deterministic":
    let tmpRoot = getTempDir() / "repro-m59-block-1"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = setupStore(tmpRoot)
    var state = newApplyState()

    proc apply(host: string; port, replicas: int):
              tuple[res: OwnedApplyResult, body: string] =
      var portH, replicasH: Configurable[int]
      var hostH: Configurable[string]
      let ctx = evalConfig:
        let p = configurable 8080
        let r = configurable 1
        let h = configurable "localhost"
        p.override port
        r.override replicas
        h.override host
        portH = p
        replicasH = r
        hostH = h
      let rendered = render(ctx, portH, replicasH, hostH)
      let res = configFile(state, store, scope,
        "~/.config/codetracer/config.toml", rendered)
      result.res = res
      result.body = readFile(res.targetPath)

    let outPath = scope.home / ".config" / "codetracer" / "config.toml"
    # First apply -> created.
    let r1 = apply("example.com", 9000, 4)
    check r1.res.targetPath == outPath
    check r1.res.outcome == oaCreated
    check "[http]" in r1.body
    check "port = 9000" in r1.body
    check "host = \"example.com\"" in r1.body
    check "count = 4" in r1.body
    # Second apply with identical inputs -> cache hit.
    let r2 = apply("example.com", 9000, 4)
    check r2.res.outcome == oaCacheHit
    check r2.body == r1.body
    # Determinism: cache key & content digest stable.
    check r2.res.cacheKeyHex == r1.res.cacheKeyHex
    check r2.res.contentDigestHex == r1.res.contentDigestHex

  test "editing an unread configurable does not invalidate":
    let tmpRoot = getTempDir() / "repro-m59-block-2"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = setupStore(tmpRoot)
    var state = newApplyState()

    proc apply(host: string; port, replicas, unused: int):
              OwnedApplyResult =
      var portH, replicasH: Configurable[int]
      var hostH: Configurable[string]
      let ctx = evalConfig:
        let p = configurable 8080
        let r = configurable 1
        let h = configurable "localhost"
        let u = configurable 0
        p.override port
        r.override replicas
        h.override host
        u.override unused
        portH = p
        replicasH = r
        hostH = h
      let rendered = render(ctx, portH, replicasH, hostH)
      result = configFile(state, store, scope,
        "~/.config/codetracer/config.toml", rendered)

    let first = apply("example.com", 9000, 4, 0)
    check first.outcome == oaCreated
    # Edit the unread `unused` configurable. The cache key MUST be
    # stable, the apply MUST be a cache hit.
    let second = apply("example.com", 9000, 4, 999)
    check second.outcome == oaCacheHit
    check second.cacheKeyHex == first.cacheKeyHex

  test "editing a read configurable rebuilds":
    let tmpRoot = getTempDir() / "repro-m59-block-3"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = setupStore(tmpRoot)
    var state = newApplyState()

    proc apply(host: string; port, replicas: int): OwnedApplyResult =
      var portH, replicasH: Configurable[int]
      var hostH: Configurable[string]
      let ctx = evalConfig:
        let p = configurable 8080
        let r = configurable 1
        let h = configurable "localhost"
        p.override port
        r.override replicas
        h.override host
        portH = p
        replicasH = r
        hostH = h
      let rendered = render(ctx, portH, replicasH, hostH)
      result = configFile(state, store, scope,
        "~/.config/codetracer/config.toml", rendered)

    let first = apply("example.com", 9000, 4)
    let second = apply("example.com", 9100, 4)
    check second.outcome == oaUpdated
    check second.cacheKeyHex != first.cacheKeyHex
    let written = readFile(second.targetPath)
    check "port = 9100" in written
    check "port = 9000" notin written

  test "deterministic bytes across independent contexts":
    # Two completely independent apply runs (fresh state, store, tmp
    # dir) with identical inputs must produce byte-identical output.
    proc oneRun(): tuple[bytes: string, cacheKey: string] =
      let tmpRoot = getTempDir() / ("repro-m59-block-det-" &
        $rand(high(int)))
      if dirExists(tmpRoot): removeDir(tmpRoot)
      createDir(tmpRoot)
      var scope = setupScope(tmpRoot)
      var store = setupStore(tmpRoot)
      var state = newApplyState()
      var portH, replicasH: Configurable[int]
      var hostH: Configurable[string]
      let ctx = evalConfig:
        let p = configurable 8080
        let r = configurable 1
        let h = configurable "localhost"
        p.override 9000
        r.override 4
        h.override "example.com"
        portH = p; replicasH = r; hostH = h
      let rendered = render(ctx, portH, replicasH, hostH)
      let res = configFile(state, store, scope,
        "~/.config/codetracer/config.toml", rendered)
      result.bytes = readFile(res.targetPath)
      result.cacheKey = res.cacheKeyHex

    let a = oneRun()
    let b = oneRun()
    check a.bytes == b.bytes
    check a.cacheKey == b.cacheKey
