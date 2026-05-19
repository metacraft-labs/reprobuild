## Smoke test for the M59 generated-config module. Verifies the
## structured serializer, the path-expansion helpers, and the managed
## block reader/writer compile and produce non-trivial output. The
## real M59 gates live under `tests/e2e/`.

import std/[os, strutils, tables, unittest]

import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/generated_config

suite "Generated-config smoke":

  test "structured TOML round-trip":
    let root = svObject()
    let db = svObject()
    db.setField("url", svString("postgres://example.com/db"))
    db.setField("pool_size", svInt(32))
    root.setField("database", db)
    let http = svObject()
    http.setField("port", svInt(8080))
    root.setField("http", http)
    let text = serializeToml(root)
    check "[database]" in text
    check "url" in text
    check "pool_size = 32" in text
    check "[http]" in text
    check "port = 8080" in text

  test "structured JSON preserves insertion order":
    let root = svObject()
    root.setField("z", svInt(1))
    root.setField("a", svInt(2))
    let s = serializeJson(root)
    let zIdx = s.find("\"z\"")
    let aIdx = s.find("\"a\"")
    check zIdx >= 0 and aIdx > zIdx

  test "tomlContent: macro with configurable reads":
    let ctx = evalConfig:
      let port = configurable 8080
      port.override 9000
    let portHandle = Configurable[int](id: ConstructionId(0))
    let rendered = tomlContent(ctx):
      http:
        port = portHandle
    check rendered.format == cfToml
    let text = renderToString(rendered)
    check "[http]" in text
    check "port = 9000" in text
    check rendered.inputs.items.len == 1

  test "path expansion is scope-checked":
    putEnv("REPRO_HOME_PROFILE_TARGET", getTempDir() / "repro-home-test")
    let scope = resolveHomeScope()
    let p = expandPath(scope, "~/.config/test.toml")
    check p.startsWith(scope.home)
    expect EOutOfScope:
      discard expandPath(scope, "/etc/passwd")
    delEnv("REPRO_HOME_PROFILE_TARGET")

  test "managed-block update/remove":
    let tmp = getTempDir() / "repro-mb-smoke.txt"
    if fileExists(tmp): removeFile(tmp)
    writeFile(tmp, "alpha\nbeta\n")
    discard updateManagedBlock(tmp, "demo", "managed line 1\nmanaged line 2")
    let c1 = readFile(tmp)
    check "alpha" in c1
    check "managed line 1" in c1
    check "managed line 2" in c1
    check ">>> repro:home:demo >>>" in c1
    check removeManagedBlock(tmp, "demo")
    let c2 = readFile(tmp)
    check "managed line 1" notin c2
    check ">>> repro:home:demo >>>" notin c2
    check "alpha" in c2
    removeFile(tmp)

  test "renderBuiltinTemplate: {{name}} + {{#if}} on typed values":
    var values = initTable[string, TplValue]()
    values["who"] = tplString("world")
    values["greet"] = tplString("true")
    values["skip"] = tplString("0")
    let src = "Hello, {{who}}!{{#if greet}} (g){{/if}}{{#if skip}} NO{{/if}}"
    let outText = renderBuiltinTemplate(src, values)
    check outText == "Hello, world! (g)"

  test "renderBuiltinTemplate: {{#each}} empty list emits no body":
    var values = initTable[string, TplValue]()
    values["xs"] = tplStringList(@[])
    let src = "head\n{{#each x in xs}}- {{x}}\n{{/each}}tail"
    let outText = renderBuiltinTemplate(src, values)
    check outText == "head\ntail"

  test "renderBuiltinTemplate: {{#each}} iterates in order":
    var values = initTable[string, TplValue]()
    values["items"] = tplStringList(@["alpha", "beta", "gamma"])
    let src = "[{{#each it in items}}{{it}};{{/each}}]"
    let outText = renderBuiltinTemplate(src, values)
    check outText == "[alpha;beta;gamma;]"

  test "renderBuiltinTemplate: nested {{#if}} inside {{#each}}":
    var values = initTable[string, TplValue]()
    values["names"] = tplStringList(@["one", "two", "three"])
    values["show"] = tplString("true")
    let src = "{{#each n in names}}{{#if show}}<{{n}}>{{/if}}{{/each}}"
    let outText = renderBuiltinTemplate(src, values)
    check outText == "<one><two><three>"

  test "renderBuiltinTemplate: {{#each}} loop var shadows then restores":
    var values = initTable[string, TplValue]()
    values["it"] = tplString("OUTER")
    values["xs"] = tplStringList(@["a", "b"])
    # Inside the loop, {{it}} should bind to the loop element; outside,
    # the original `it` value remains.
    let src = "before={{it}};loop={{#each it in xs}}{{it}},{{/each}};" &
      "after={{it}}"
    let outText = renderBuiltinTemplate(src, values)
    check outText == "before=OUTER;loop=a,b,;after=OUTER"

  test "renderBuiltinTemplate: {{#each}} missing list raises":
    var values = initTable[string, TplValue]()
    let src = "{{#each x in missing}}{{x}}{{/each}}"
    expect EBuiltinTemplate:
      discard renderBuiltinTemplate(src, values)

  test "renderBuiltinTemplate: {{#each}} on wrong-type variable raises":
    var values = initTable[string, TplValue]()
    values["s"] = tplString("hello")
    let src = "{{#each c in s}}{{c}}{{/each}}"
    expect EBuiltinTemplate:
      discard renderBuiltinTemplate(src, values)

  test "renderBuiltinTemplate: {{name}} on list-typed variable raises":
    var values = initTable[string, TplValue]()
    values["xs"] = tplStringList(@["a", "b"])
    expect EBuiltinTemplate:
      discard renderBuiltinTemplate("{{xs}}", values)

  test "renderBuiltinTemplate: {{#if}} on tvStringList raises EBuiltinTemplate":
    var values = initTable[string, TplValue]()
    values["xs"] = tplStringList(@["a", "b"])
    let src = "{{#if xs}}body{{/if}}"
    expect EBuiltinTemplate:
      discard renderBuiltinTemplate(src, values)

  test "renderBuiltinTemplate: back-compat string-table overload still works":
    var sv = initTable[string, string]()
    sv["who"] = "world"
    check renderBuiltinTemplate("hi {{who}}", sv) == "hi world"
