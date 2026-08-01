## Typed-Extension-Interfaces M4a — the C-ABI **library** transport for the
## resource-reconcile leaf ops (Low-Level-Provider-Protocol.md §6).
##
## A mock resource provider is compiled as a linkable library (``--app:lib``,
## ``--define:reproProviderMode``) that exports the C ABI from ``library_abi.nim``
## (``repro_provider_open`` / ``repro_resource_{digest,observe,apply}`` /
## ``repro_*_free`` / ``repro_provider_close``). The engine ``dlopen``s it and
## reconciles a resource over the C-ABI transport — regular cdecl calls on
## C-typed ``(ptr,len)`` params, NO process spawn, NO socket, NO SSZ.
##
## NON-VACUITY / no-spawn witness: the provider records (via
## ``repro_provider_call_count``) that its ops were served IN-PROCESS over the
## ABI, and the reconcile runs with a ``ResourceSessionResolver`` that raises if
## ever called — so no session pipe / provider process is opened. The engine
## also has NO in-process driver registered for the type, so only the library
## transport (or a session) could converge it.
##
## FALLBACK INTACT: the SAME provider logic, registered in-process, reconciles
## the same instance over ``reconcileResources`` — one abstract contract, two
## renderings.

import std/[dynlib, options, os, osproc, strutils, unittest]

import repro_resources
import repro_resources/library_transport
import repro_provider_runtime
import repro_interface_artifacts
import repro_project_dsl

# The engine side holds ONLY the attrs marshaller (never the driver) — the
# RP5a "consumer has the contract, not the impl" boundary. The library carries
# the driver.
type
  CounterAttrs = object
    name*: string
    target*: int

registerExtension[CounterAttrs]("m4a.counter")

# ---------------------------------------------------------------------------
# The mock provider source. A resource type ``m4a.counter`` whose driver's
# "world" is an on-disk file holding an integer; ``apply`` writes ``target``,
# ``observe`` reads it. Compiled ``--app:lib`` it exports the C ABI via the
# provider-mode ``{.exportc, dynlib.}`` procs in ``library_abi.nim``.
# ---------------------------------------------------------------------------

const providerBody = """
import std/[options, os, strutils]
import repro_resources
import repro_project_dsl

type
  CounterAttrs = object
    name*: string
    target*: int

proc cIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  "counter:" & a.name

proc cDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  digestString(inst.address & "\x00" & $a.target)

proc cObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  let path = getEnv("M4A_WORLD")
  if fileExists(path):
    let cur = readFile(path).strip()
    result.present = true
    result.digest = digestString(inst.address & "\x00" & cur)
  else:
    result.present = false

proc cApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  writeFile(getEnv("M4A_WORLD"), $a.target)
  result = ResourceBinding(
    address: inst.address,
    typeId: inst.typeId,
    resourceId: cIdentity(inst),
    postWriteDigest: cDigest(inst),
    present: true)

registerResourceProvider(ResourceProviderDef(
  typeId: "m4a.counter",
  determinism: rdVolatile,
  driver: ResourceProviderDriver(
    identity: cIdentity, digest: cDigest,
    observe: cObserve, apply: cApply)))
registerExtension[CounterAttrs]("m4a.counter")
"""

# The in-process copy of the same driver logic (fallback path).
proc ipIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  "counter:" & a.name
proc ipDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  digestString(inst.address & "\x00" & $a.target)
proc ipObserve(inst: ResourceInstance;
               recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let path = getEnv("M4A_WORLD")
  if fileExists(path):
    let cur = readFile(path).strip()
    result.present = true
    result.digest = digestString(inst.address & "\x00" & cur)
  else:
    result.present = false
proc ipApply(inst: ResourceInstance; action: ResourceActionKind;
             observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  writeFile(getEnv("M4A_WORLD"), $a.target)
  ResourceBinding(address: inst.address, typeId: inst.typeId,
    resourceId: ipIdentity(inst), postWriteDigest: ipDigest(inst), present: true)

proc soExt(): string =
  when defined(windows): "dll"
  elif defined(macosx): "dylib"
  else: "so"

proc buildProviderLibrary(tempRoot: string): string =
  ## Compile the mock provider source as a shared library exposing the C ABI.
  ## Reuses the repo's ``config.nims`` ``--path`` set so ``repro_resources`` &
  ## its deps resolve; adds ``--app:lib`` + ``--define:reproProviderMode`` so
  ## the ``library_abi.nim`` exportc procs are emitted.
  let projDir = tempRoot / "provider"
  createDir(projDir)
  let modulePath = projDir / "mock_provider.nim"
  writeFile(modulePath, providerBody)
  let soPath = tempRoot / ("libm4a_mock_provider." & soExt())
  let repoRoot = getCurrentDir()
  # Reuse the engine's provider-compile command (it carries the full repro lib
  # + package --path set + host flags + ``--define:reproProviderMode``,
  # independent of config.nims which is projectdir-scoped), then render it as a
  # LIBRARY by appending ``--app:lib`` — the C-ABI ``{.exportc, dynlib.}`` procs
  # in ``library_abi.nim`` are then emitted. (M4a proves the transport with a
  # mock lib; the full "provider library build edge" — §4.3 — is M4-later.)
  var cmd = providerCompileCommand(modulePath, soPath, repoRoot,
    scratchDir = tempRoot)
  # The module path is the LAST argument; flags after it are treated as run
  # args. Insert the library toggles just before it.
  cmd.insert("--app:lib", cmd.len - 1)
  let (output, code) = execCmdEx(quoteShellCommand(cmd), workingDir = repoRoot)
  if code != 0 or not fileExists(soPath):
    raise newException(IOError,
      "mock provider library build failed (exit " & $code & "):\n" & output)
  soPath

proc desiredInstance(name: string; target: int): ResourceInstance =
  ResourceInstance(
    typeId: "m4a.counter",
    address: "ctr",
    attrs: TypedExtensionBox[CounterAttrs](
      typeId: "m4a.counter",
      val: CounterAttrs(name: name, target: target)),
    dependsOn: @[],
    determinism: rdVolatile)

suite "M4a: resource reconcile over the C-ABI library transport":

  test "reconcile drives digest->observe->apply over the C ABI (no spawn), session fallback intact":
    let tempRoot = getTempDir() / ("m4a-" & $getCurrentProcessId())
    removeDir(tempRoot)
    createDir(tempRoot)
    defer: removeDir(tempRoot)

    let soPath = buildProviderLibrary(tempRoot)
    check fileExists(soPath)

    # NON-VACUITY: the engine has NO in-process driver for the type — an
    # in-process ``reconcileResources`` on it would hard-error, so only the
    # library (or session) transport can converge it.
    resetDesiredResources()
    check not isResourceProviderRegistered("m4a.counter")

    let worldPath = tempRoot / "world.txt"
    putEnv("M4A_WORLD", worldPath)
    check not fileExists(worldPath)

    # dlopen the provider .so and bind the C ABI (RAII handle).
    let lib = loadResourceProviderLibrary(soPath)

    # Library resolver: return the loaded lib for our type. Session resolver:
    # RAISE if ever consulted — proving NO session pipe / process is opened.
    let libResolve: ResourceLibraryResolver = proc (typeId: string): pointer =
      if typeId == "m4a.counter": cast[pointer](lib) else: nil
    let sessResolve: ResourceSessionResolver = proc (typeId: string): ProviderHandle =
      raise newException(AssertionDefect,
        "session resolver consulted — the library transport did NOT run in-process")

    check lib.callCount() == 0

    # ── FIRST reconcile: create over the C ABI ─────────────────────────────
    let inst = desiredInstance("hits", 7)
    let first = reconcileResourcesViaSession(@[inst], sessResolve,
      library = libResolve)
    check first.actions.len == 1
    check first.actions[0].kind == rakCreate
    check first.bindings.len == 1
    check first.bindings[0].resourceId == "counter:hits"

    # The world was mutated via the library's apply, over the ABI.
    check fileExists(worldPath)
    check readFile(worldPath).strip() == "7"

    # NO-SPAWN WITNESS: the provider served the ops IN-PROCESS over the ABI
    # (digest + observe + apply => 3 calls), and the session resolver was never
    # consulted (it would have raised).
    check lib.callCount() == 3

    # ── SECOND reconcile: no-op (observe sees the library's own write) ─────
    let second = reconcileResourcesViaSession(@[inst], sessResolve,
      recorded = first.bindings, library = libResolve)
    check second.actions.len == 1
    check second.actions[0].kind == rakNoOp
    check readFile(worldPath).strip() == "7"

    # ── CHANGED target: an update over the C ABI ───────────────────────────
    let inst2 = desiredInstance("hits", 42)
    let third = reconcileResourcesViaSession(@[inst2], sessResolve,
      recorded = second.bindings, library = libResolve)
    check third.actions.len == 1
    check third.actions[0].kind == rakUpdate
    check readFile(worldPath).strip() == "42"

    # ── FALLBACK: the SAME logic registered IN-PROCESS converges identically ─
    removeFile(worldPath)
    resetDesiredResources()
    registerResourceProvider(ResourceProviderDef(
      typeId: "m4a.counter",
      determinism: rdVolatile,
      driver: ResourceProviderDriver(
        identity: ipIdentity, digest: ipDigest,
        observe: ipObserve, apply: ipApply)))
    let ip = reconcileResources(@[desiredInstance("hits", 7)])
    check ip.actions.len == 1
    check ip.actions[0].kind == rakCreate
    check readFile(worldPath).strip() == "7"

  test "t_provider_library_c_abi_memory_ownership: exported free + RAII, defined empty out on error":
    let tempRoot = getTempDir() / ("m4a-own-" & $getCurrentProcessId())
    removeDir(tempRoot)
    createDir(tempRoot)
    defer: removeDir(tempRoot)

    let soPath = buildProviderLibrary(tempRoot)
    putEnv("M4A_WORLD", tempRoot / "world.txt")

    let lib = loadResourceProviderLibrary(soPath)
    let inst = desiredInstance("own", 1)

    # Every op allocates an OWNED result buffer on the LIBRARY heap that the
    # transport releases through the callee-EXPORTED ``repro_buffer_free`` (never
    # the engine's own free — §6.2). Run the op many times: if the exported free
    # were mismatched with the alloc heap, a cross-heap free would corrupt /
    # crash long before N iterations. Surviving N clean alloc/free crossings is
    # the balance witness.
    for i in 0 ..< 500:
      discard digestViaLibrary(lib, inst)
    check lib.callCount() == 500

    # RAII: dropping the last ref to the loaded library runs ``=destroy`` which
    # calls the callee-exported ``repro_provider_close`` and unloads the .so.
    # No manual close; a leaked dlopen / provider handle is hard to write.
    var scoped = loadResourceProviderLibrary(soPath)
    discard digestViaLibrary(scoped, inst)
    scoped = nil          # triggers =destroy (close + unload)
    GC_fullCollect()
    check true            # reaching here without a crash proves clean teardown

    # ERROR path: a bad ABI version leaves the out-handle in a DEFINED empty
    # state (nil) and returns a negative status — NO exception crosses the ABI.
    # (Re-load a fresh lib so we can bind ``repro_provider_open`` directly.)
    block:
      let raw = loadLib(soPath)
      check raw != nil
      let openFn = cast[proc (v: uint32; h: ptr pointer): cint {.cdecl.}](
        symAddr(raw, "repro_provider_open"))
      var h: pointer = cast[pointer](0xdeadbeef)
      let st = openFn(uint32(ReproAbiVersion) + 7'u32, addr h)
      check st != 0            # negative error status, not a panic
      check h == nil           # out-param left in the defined empty state
      unloadLib(raw)
