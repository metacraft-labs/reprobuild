## Shared-Development-Services L1 — a ``service <ident>:`` block records
## TYPED executable / args / runtime-file edges, not a metadata string.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion reads the real registry the real ``package`` macro
## populated from a real ``service <ident>:`` block in this module, and the
## codec assertions run the real encoder and decoder over those records. A
## hand-built ``DslServiceDef`` would make the file vacuous: the thing under
## test is what the MACRO lowers, so the macro has to be what produced it.
##
## Governing spec text:
##
## * ``Package-Model.md`` §Collections — the setter list: "``executable
##   <expr>``", "``args "...", "...", ...``", "``runtimeFile
##   <buildOutput>``", "``on <trigger>:`` blocks", and "``service`` does
##   not have a ``config:`` setter."
## * ``Package-Model.md`` §Collections — "When the file *is* passed on
##   argv, no ``runtimeFile`` line is needed: a ``BuildOutput.path``
##   reaches ``args`` as a context-carrying string and the framework
##   records the edge through the typed proxy, just as Nix's
##   string-with-context records derivation references inside ordinary
##   string splices."
## * ``Shared-Development-Services.md`` §1 — the defect: "a name, an
##   activity list and an **opaque metadata string** the engine
##   interprets. There is no composition, no typed reference".
##
## The control that keeps this non-vacuous is ``argsPlainPkg`` below: a
## bare string argument must record NO producer. A design that stamped the
## enclosing render's edge onto every argument would pass every positive
## case here and fail that one.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

# The rendered configuration. Declared at module scope and assigned from
# the package's ``build:`` body, which is the shape ``t_dsl_output_ref``
# already uses for a ``DslOutputRef``: the build body runs at module-init
# time (non-provider mode) BEFORE the service emission, so the service
# body below reads an assigned handle.
var apiConfig: BuildOutput
var apiSecrets: BuildOutput

package typedSvcPkg:
  executable apiBin:
    build:
      output("bin/api")

  build:
    apiConfig = renderConfigFile("etc/api/config.toml",
      "issuer = \"http://localhost:8080\"\n")
    apiSecrets = renderConfigFile("etc/api/secrets.toml",
      "token = \"dev\"\n")

  service api:
    executable apiBin
    args "--issuer", "http://localhost:8080",
         "--config", apiConfig.path,
         "--config-backup=" & apiConfig.path
    runtimeFile apiSecrets
    on change apiConfig:
      sendSignal "SIGHUP"
    on crash:
      restart
    on rebuild apiBin:
      hotReload
    restartOnCrash

# The control. A service whose arguments are all plain strings must record
# NO producer on any of them -- otherwise "the argument carries its edge"
# is indistinguishable from "every argument is stamped with whatever edge
# was lying around".
package argsPlainPkg:
  executable plainBin:
    build:
      discard
  service plain:
    executable plainBin
    args "etc/api/config.toml"

# The third-party form: ``<pkg>.executable("<name>")``. ``Package-Model.md``
# names this case explicitly ("such as ``redis.executable("redis-server")``
# for third-party software pulled in via ``uses``").
#
# Two spellings, because they reach DIFFERENT overloads and only one of
# them has a type to overload on. ``<pkg>.executable(name)`` returns a
# PER-PACKAGE wrapper type the ``package`` macro emits (``macros_a.nim``'s
# ``exeTypeName``) -- a type that does not exist until that macro expands,
# so it is unwrapped structurally by the generic arm. The bare
# ``selectedExecutable(...)`` hits the concrete overload. A test of only
# the concrete one would leave the generic arm unexecuted.
package providerSvcPkg:
  executable redisServer:
    build:
      output("bin/redis-server")

package thirdPartySvcPkg:
  service cache:
    executable providerSvcPkg.executable("redisServer")
    args "--port", "6379"

  service cacheReplica:
    executable selectedExecutable("redis", "redis-server")
    args "--port", "6380"

# The literal-path form, kept distinct from the bare-string form on purpose:
# ``setActiveServiceExecutable(string)`` has always meant "an artifact of
# this package", so a path goes through ``executableAtPath``.
package pathSvcPkg:
  service edge:
    executable executableAtPath("/usr/sbin/nginx")
    args "-c", "/etc/nginx/nginx.conf"

# Supervisor options on `restart`, which `Package-Model.md` §"Service
# Lifecycle And Reactive Triggers" specifies as a LIST -- "Optional named
# arguments configure supervisor-level policy: `backoff =
# exponential|linear|fixed`, `maxRetries = <n>`, `delay = "5s"`". No
# lowering consumes them yet, so they are carried as the option's source
# text; carrying only the FIRST of them is the same silent drop as the
# ones `t_dsl_service_setter_surface_is_typed.nim` now refuses, with the
# extra sting that it is not even a misspelling -- it is the spec's own
# spelling, partially recorded.
#
# `exponential` and `linear` are undeclared identifiers on purpose: the
# option text is never spliced, so it must never reach the compiler. If
# this package stops compiling, that property has broken.
package triggerOptionsPkg:
  executable optBin:
    build:
      discard
  service opt:
    executable optBin
    on crash:
      restart backoff = exponential, maxRetries = 3
    restartOnCrash backoff = linear, delay = "5s"

# `hotReload otherwise <action>` — the explicit not-supported branch
# `Package-Model.md` §"Service Lifecycle And Reactive Triggers" specifies:
# "The fallback can be replaced explicitly with `hotReload otherwise
# <action>` when authors want a different not-supported branch (for
# example, `hotReload otherwise sendSignal "SIGHUP"`)."
#
# This package exists to make the answer to "why is THIS specified-but-
# unconsumed spelling accepted when `debounce` is refused?" a measurement
# rather than an argument. The difference is not whether a lowering
# consumes it -- none consumes either -- but whether the record can HOLD
# it: the fallback lands in `ServiceTriggerAction.argument`, the same slot
# `restart`'s supervisor options use, and travels on the wire with the
# service. A modifier has no slot at all, so accepting one would discard
# it. If this assertion ever reads an empty argument, `hotReload
# otherwise` has become the silent drop the modifiers are refused for and
# belongs in the refusal set with them.
#
# `otherwise` is an undeclared identifier, for the same reason
# `exponential` is above: option text is never spliced.
package triggerFallbackPkg:
  executable fallbackBin:
    build:
      discard
  service fallback:
    executable fallbackBin
    on rebuild fallbackBin:
      hotReload otherwise sendSignal "SIGHUP"

proc serviceNamed(packageName, serviceName: string): DslServiceDef =
  for svc in registeredServices(packageName):
    if svc.serviceName == serviceName:
      return svc
  raise newException(ValueError,
    "no service " & serviceName & " in package " & packageName)

suite "L1 — the service block's typed executable edge":

  test "`executable <ident>` records the artifact, by name, unevaluated":
    let svc = serviceNamed("typedSvcPkg", "api")
    check svc.executableTyped.kind == sxkArtifact
    check svc.executableTyped.executableName == "apiBin"
    check svc.executableTyped.packageName == "typedSvcPkg"
    # The M5 acceptance field is unchanged — this milestone is additive.
    check svc.executableRef == "apiBin"
    check svc.executable == "apiBin"

  test "`executable <pkg>.executable(name)` records package + name":
    # The generic arm: a per-package wrapper type, unwrapped structurally.
    let svc = serviceNamed("thirdPartySvcPkg", "cache")
    check svc.executableTyped.kind == sxkPackageExecutable
    check svc.executableTyped.packageName == "providerSvcPkg"
    check svc.executableTyped.executableName == "redisServer"

  test "`executable selectedExecutable(pkg, name)` records the same shape":
    # The concrete arm, over a package this recipe never declares -- the
    # third-party case the spec's wording is about.
    let svc = serviceNamed("thirdPartySvcPkg", "cacheReplica")
    check svc.executableTyped.kind == sxkPackageExecutable
    check svc.executableTyped.packageName == "redis"
    check svc.executableTyped.executableName == "redis-server"

  test "`executable executableAtPath(path)` records the path":
    let svc = serviceNamed("pathSvcPkg", "edge")
    check svc.executableTyped.kind == sxkPath
    check svc.executableTyped.path == "/usr/sbin/nginx"

suite "L1 — args carry the producing edge, and only when they have one":

  test "every argument reaches the record, in declaration order":
    let svc = serviceNamed("typedSvcPkg", "api")
    check svc.typedArgs.len == 5
    check svc.args.len == 5
    # M5 accepted string LITERALS only and silently dropped everything
    # else, so this ordering is also the regression check for the drop.
    check svc.args == @["--issuer", "http://localhost:8080",
                        "--config", "etc/api/config.toml",
                        "--config-backup=etc/api/config.toml"]
    for i in 0 ..< svc.typedArgs.len:
      check svc.typedArgs[i].value == svc.args[i]

  test "a build-output argument records its producing action":
    let svc = serviceNamed("typedSvcPkg", "api")
    check svc.typedArgs[3].kind == svakBuildOutput
    check svc.typedArgs[3].value == "etc/api/config.toml"
    check svc.typedArgs[3].producerPath == "etc/api/config.toml"
    check svc.typedArgs[3].producerActionId == apiConfig.actionId
    check svc.typedArgs[3].producerActionId.len > 0
    check svc.typedArgs[3].producerPackage == "typedSvcPkg"

  test "concatenation keeps the context — Nix's string-with-context rule":
    let svc = serviceNamed("typedSvcPkg", "api")
    check svc.typedArgs[4].kind == svakBuildOutput
    check svc.typedArgs[4].value ==
      "--config-backup=etc/api/config.toml"
    check svc.typedArgs[4].producerActionId == apiConfig.actionId
    # ... and the producer PATH stays the file's own path, not the
    # concatenated argv token, because that is what the producing edge
    # declares and what the graph has to match on.
    check svc.typedArgs[4].producerPath == "etc/api/config.toml"

  test "a plain string argument records NO producer (the control)":
    let svc = serviceNamed("typedSvcPkg", "api")
    for i in [0, 1, 2]:
      check svc.typedArgs[i].kind == svakLiteral
      check svc.typedArgs[i].producerActionId == ""
      check svc.typedArgs[i].producerPath == ""
    # Same string, written as a literal rather than as a handle, in a
    # package that never rendered anything: still no producer.
    let control = serviceNamed("argsPlainPkg", "plain")
    check control.typedArgs.len == 1
    check control.typedArgs[0].value == "etc/api/config.toml"
    check control.typedArgs[0].kind == svakLiteral
    check control.typedArgs[0].producerActionId == ""

suite "L1 — runtimeFile and the reactive surface":

  test "`runtimeFile <buildOutput>` records the path and its producer":
    let svc = serviceNamed("typedSvcPkg", "api")
    check svc.runtimeFiles.len == 1
    check svc.runtimeFiles[0].path == "etc/api/secrets.toml"
    check svc.runtimeFiles[0].producerActionId == apiSecrets.actionId
    check svc.runtimeFiles[0].producerActionId.len > 0
    check svc.runtimeFiles[0].producerPackage == "typedSvcPkg"
    # The two renders are distinct edges, which is what makes the
    # runtime-file assertion above mean something.
    check apiSecrets.actionId != apiConfig.actionId

  test "`on <trigger>:` blocks and the short-form atom all land, in order":
    let svc = serviceNamed("typedSvcPkg", "api")
    check svc.triggers.len == 4

    check svc.triggers[0].kind == stkChangeOutput
    check svc.triggers[0].subject == "etc/api/config.toml"
    check svc.triggers[0].producerActionId == apiConfig.actionId
    check svc.triggers[0].actions.len == 1
    check svc.triggers[0].actions[0].kind == stakSendSignal
    check svc.triggers[0].actions[0].argument == "SIGHUP"

    check svc.triggers[1].kind == stkCrash
    check svc.triggers[1].actions.len == 1
    check svc.triggers[1].actions[0].kind == stakRestart

    check svc.triggers[2].kind == stkRebuild
    check svc.triggers[2].subject == "apiBin"
    check svc.triggers[2].actions.len == 1
    check svc.triggers[2].actions[0].kind == stakHotReload

    # ``restartOnCrash`` = ``on crash: restart``. A bare ident statement,
    # which the M5 walker skipped before reaching any arm.
    check svc.triggers[3].kind == stkCrash
    check svc.triggers[3].actions.len == 1
    check svc.triggers[3].actions[0].kind == stakRestart

suite "L1 — the service's producer edge set":

  test "serviceProducerActionIds names each distinct producer once":
    let svc = serviceNamed("typedSvcPkg", "api")
    let producers = svc.serviceProducerActionIds()
    check producers.len == 2
    check apiConfig.actionId in producers
    check apiSecrets.actionId in producers

  test "serviceConsumedOutputs pairs each producer with its own path":
    let svc = serviceNamed("typedSvcPkg", "api")
    let consumed = svc.serviceConsumedOutputs()
    check consumed.len == 2
    check (actionId: apiConfig.actionId,
           path: "etc/api/config.toml") in consumed
    check (actionId: apiSecrets.actionId,
           path: "etc/api/secrets.toml") in consumed

  test "a service with no build outputs has an empty producer set":
    let control = serviceNamed("argsPlainPkg", "plain")
    check control.serviceProducerActionIds().len == 0
    check control.serviceConsumedOutputs().len == 0

suite "L1 — the handle's `path` is a FIELD, not an exported accessor":

  test "importing the DSL does not bind `path`":
    # ``cfg.path`` has to be FIELD access. A top-level ``proc path*`` in
    # the DSL gives the same call syntax at the author's end and puts
    # ``path`` into the namespace of every recipe that imports the DSL —
    # which ``t_dsl_tool_provisioning_staged.nim`` refuses by name,
    # because ``path`` is a tool-provisioning vocabulary word scoped to
    # its own expression. The first draft of this milestone used an
    # accessor proc and reddened that test. The control lives here too,
    # beside the feature that depends on the choice.
    check not declared(path)

  test "and the field carries the producer, in sync with `filePath`":
    check apiConfig.path.value == apiConfig.filePath
    check apiConfig.path.producerPath == apiConfig.filePath
    check apiConfig.path.producerActionId == apiConfig.actionId
    check apiConfig.path.producerPackage == apiConfig.packageName

suite "L1 — the typed record survives the gnkService payload codec":

  test "encode + decode round-trips every typed field":
    let svc = serviceNamed("typedSvcPkg", "api")
    let decoded = decodeServicePayload(encodeServicePayload(svc))
    check decoded.packageName == svc.packageName
    check decoded.serviceName == svc.serviceName
    check decoded.executableTyped == svc.executableTyped
    check decoded.executableRef == svc.executableRef
    check decoded.executable == svc.executable
    check decoded.typedArgs == svc.typedArgs
    check decoded.args == svc.args
    check decoded.runtimeFiles == svc.runtimeFiles
    check decoded.triggers == svc.triggers

  test "the M9.C systemd slice round-trips too":
    let svc = serviceNamed("pathSvcPkg", "edge")
    let decoded = decodeServicePayload(encodeServicePayload(svc))
    check decoded.executableTyped == svc.executableTyped
    check decoded.typedArgs == svc.typedArgs
    check decoded.description == svc.description
    check decoded.serviceType == svc.serviceType
    check decoded.execStart == svc.execStart
    check decoded.wantedBy == svc.wantedBy
    check decoded.wants == svc.wants
    check decoded.requires == svc.requires
    check decoded.before == svc.before
    check decoded.after == svc.after
    check decoded.env == svc.env
    check decoded.restart == svc.restart
    check decoded.user == svc.user
    check decoded.group == svc.group

  test "a legacy positional registration round-trips its untyped fields":
    # ``registerService`` (the M5/M9.C positional entry point) populates
    # ``executableRef`` and ``args`` and leaves the typed fields empty.
    # The codec must carry those two rather than deriving them from the
    # typed record, or this record would come back with no arguments.
    let legacy = DslServiceDef(
      packageName: "legacyPkg", serviceName: "legacy",
      executableRef: "legacyBin", executable: "legacyBin",
      args: @["--flag", "value"],
      description: "a legacy row", serviceType: "simple",
      wantedBy: @["multi-user.target"])
    let decoded = decodeServicePayload(encodeServicePayload(legacy))
    check decoded.executableRef == "legacyBin"
    check decoded.executable == "legacyBin"
    check decoded.args == @["--flag", "value"]
    check decoded.typedArgs.len == 0
    check decoded.executableTyped.kind == sxkUnset
    check decoded.description == "a legacy row"
    check decoded.wantedBy == @["multi-user.target"]

  test "a payload from another schema is refused, not misread":
    # The envelope's job. Without it a stale decoder reads a newer
    # payload as a corrupt one.
    var bytes = encodeServicePayload(serviceNamed("pathSvcPkg", "edge"))
    bytes[0] = byte(ord('X'))
    expect CatchableError:
      discard decodeServicePayload(bytes)

suite "L1 follow-up — supervisor options are carried whole, not truncated":

  test "`restart` keeps every named option, not just the first":
    let svc = serviceNamed("triggerOptionsPkg", "opt")
    check svc.triggers.len == 2
    check svc.triggers[0].kind == stkCrash
    check svc.triggers[0].actions.len == 1
    check svc.triggers[0].actions[0].kind == stakRestart
    check svc.triggers[0].actions[0].argument ==
      "backoff = exponential, maxRetries = 3"

  test "and so does the `restartOnCrash` short form":
    let svc = serviceNamed("triggerOptionsPkg", "opt")
    check svc.triggers[1].kind == stkCrash
    check svc.triggers[1].actions.len == 1
    check svc.triggers[1].actions[0].kind == stakRestart
    check svc.triggers[1].actions[0].argument ==
      "backoff = linear, delay = \"5s\""

  test "`hotReload otherwise <action>` is RECORDED, not merely accepted":
    # The companion to the modifier refusals in
    # `t_dsl_service_setter_surface_is_typed.nim`. This spelling is
    # specified and unconsumed too, and it compiles -- which is only
    # defensible because the fallback reaches the record instead of
    # evaporating. That is what this asserts, so the distinction the
    # refusals rest on is measured and falsifiable rather than asserted
    # in a comment.
    let svc = serviceNamed("triggerFallbackPkg", "fallback")
    check svc.triggers.len == 1
    check svc.triggers[0].kind == stkRebuild
    check svc.triggers[0].subject == "fallbackBin"
    check svc.triggers[0].actions.len == 1
    check svc.triggers[0].actions[0].kind == stakHotReload
    check svc.triggers[0].actions[0].argument ==
      "otherwise sendSignal \"SIGHUP\""
