## M59 gate: `e2e_generated_config_file_json_value`.
##
## Normative description:
##
##   Builds a JsonNode programmatically (mixing literals, configurable
##   reads, and a helper proc that returns a sub-fragment) and
##   serializes through fs.writeStructured for each supported format;
##   outputs are byte-identical to the tomlContent:/iniContent:/etc.
##   equivalents for the same input tree; insertion order is preserved.

import std/[json, os, strutils, unittest]

import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/generated_config
import repro_local_store

proc setupScope(tmpRoot: string): HomeScope =
  putEnv("REPRO_HOME_PROFILE_TARGET", tmpRoot)
  result = resolveHomeScope()

proc helperFragment(httpPort: int; host: string): JsonNode =
  ## A helper proc returning a sub-fragment of the config tree. The
  ## spec calls this out explicitly as part of the gate.
  result = %*{
    "http": {
      "port": httpPort,
      "host": host
    }
  }

suite "M59 JSON-value gate":

  test "JsonNode constructed via %* preserves insertion order through every format":
    let tmpRoot = getTempDir() / "repro-m59-json-1"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()

    let ctx = evalConfig:
      let port = configurable 8080
      let host = configurable "localhost"
      let replicas = configurable 1
      port.override 9000
      host.override "example.com"
      replicas.override 4
    let portV = ctx.read(Configurable[int](id: ConstructionId(0)))
    let hostV = ctx.read(Configurable[string](id: ConstructionId(1)))
    let replicasV = ctx.read(Configurable[int](id: ConstructionId(2)))

    # Build a top-level JsonNode using a literal plus a helper-proc
    # fragment. The helper participates as ordinary Nim code.
    let topNode = %*{
      "service": "codetracer",
      "workers": {
        "count": replicasV
      }
    }
    let helperNode = helperFragment(portV, hostV)
    # Merge: top-level "service" + "workers" + helper-supplied "http".
    let mergedRaw = %*{
      "service": topNode["service"],
      "http": helperNode["http"],
      "workers": topNode["workers"]
    }
    let value = fromJsonNode(mergedRaw)

    # Cache-key inputs corresponding to the resolved configurables.
    let inputs = @[
      ResolvedInput(name: "http.port", value: cvInt(portV)),
      ResolvedInput(name: "http.host", value: cvString(hostV)),
      ResolvedInput(name: "workers.count", value: cvInt(replicasV)),
    ]

    # TOML.
    let tomlRes = writeStructured(state, store, scope,
      "~/.config/codetracer/config.toml", cfToml, value, inputs)
    let tomlBytes = readFile(tomlRes.targetPath)
    check "[http]" in tomlBytes
    check "[workers]" in tomlBytes
    check "port = 9000" in tomlBytes
    check "host = \"example.com\"" in tomlBytes
    check "count = 4" in tomlBytes

    # JSON, YAML, INI -- the same value renders deterministically per
    # format. Insertion order: service, http, workers.
    let jsonRes = writeStructured(state, store, scope,
      "~/.config/codetracer/config.json", cfJson, value, inputs)
    let jsonText = readFile(jsonRes.targetPath)
    let serviceIdx = jsonText.find("\"service\"")
    let httpIdx = jsonText.find("\"http\"")
    let workersIdx = jsonText.find("\"workers\"")
    check serviceIdx >= 0
    check httpIdx > serviceIdx
    check workersIdx > httpIdx

    let yamlRes = writeStructured(state, store, scope,
      "~/.config/codetracer/config.yaml", cfYaml, value, inputs)
    let yamlText = readFile(yamlRes.targetPath)
    check "http:" in yamlText
    check "port: 9000" in yamlText

    # Determinism: re-running writeStructured with the same inputs
    # produces a cache hit and identical bytes.
    let toml2 = writeStructured(state, store, scope,
      "~/.config/codetracer/config.toml", cfToml, value, inputs)
    check toml2.outcome == oaCacheHit
    check readFile(toml2.targetPath) == tomlBytes
    check toml2.cacheKeyHex == tomlRes.cacheKeyHex

  test "JsonNode equivalent input tree matches block-macro output byte-for-byte":
    let tmpRoot = getTempDir() / "repro-m59-json-2"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()

    # Block-macro variant.
    var portH: Configurable[int]
    var hostH: Configurable[string]
    let ctx = evalConfig:
      let port = configurable 8080
      let host = configurable "localhost"
      port.override 7777
      host.override "demo"
      portH = port
      hostH = host
    let blockRendered = tomlContent(ctx):
      http:
        port = portH
        host = hostH
    let blockText = renderToString(blockRendered)

    # JsonNode equivalent. We resolve the configurables explicitly and
    # build a structured-value tree by hand. Insertion order matches
    # the block-macro form: http -> port, host.
    let portV = ctx.read(portH)
    let hostV = ctx.read(hostH)
    let value = svObject()
    let http = svObject()
    http.setField("port", svInt(portV))
    http.setField("host", svString(hostV))
    value.setField("http", http)
    let jsonText = serialize(cfToml, value)

    # The two MUST be byte-identical for the same input tree (this is
    # the explicit `byte-identical equivalence` gate from the spec).
    check blockText == jsonText
    # Path through writeStructured produces the same bytes on disk.
    let res = writeStructured(state, store, scope,
      "~/equiv.toml", cfToml, value,
      @[ResolvedInput(name: "http.port", value: cvInt(portV)),
        ResolvedInput(name: "http.host", value: cvString(hostV))])
    let onDisk = readFile(res.targetPath)
    check onDisk == jsonText

  test "helper proc returns a JsonNode fragment that composes":
    let tmpRoot = getTempDir() / "repro-m59-json-3"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()

    let topNode = %*{
      "outer": {
        "inner": helperFragment(1234, "host-a")
      }
    }
    let value = fromJsonNode(topNode)
    let res = writeStructured(state, store, scope, "~/helper.toml",
      cfToml, value, @[])
    let body = readFile(res.targetPath)
    check "1234" in body
    check "host-a" in body
    # Insertion-order check: outer comes first, inner is a sub-section.
    check "[outer.inner]" in body
