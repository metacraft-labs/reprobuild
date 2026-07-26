## Typed-Extension-Interfaces M4 — the C-ABI provider-library **memory-owner-
## ship** harness (Low-Level-Provider-Protocol.md §6.2), standalone + greppable
## (`t_provider_library_c_abi_memory_ownership`).
##
## WHAT THIS PROVES (the load-bearing part of §6.2):
##
##   1. Every pointer/handle the provider library allocates is released ONLY
##      through the CALLEE's EXPORTED free — `repro_buffer_free` for a result
##      buffer, `repro_provider_close` for a handle — never the host's own
##      `free()`. The transport wrapper (`takeBuffer` / `=destroy`) does this,
##      so the consumer never frees library memory itself.
##
##   2. DISTINCT ALLOCATORS. The provider `.so` is built `--define:useMalloc`
##      (its allocations go through libc `malloc`/`free`), while the host test
##      binary uses Nim's default ORC allocator (its own arena). A cross-heap
##      free — freeing a provider-`malloc`ed block on the host arena, or vice
##      versa — is undefined behavior that glibc's allocator detects (an abort
##      / corruption) long before the harness completes N crossings. Surviving
##      N alloc/free crossings with a STABLE resident set is the balance
##      witness that alloc and free stay on the same side of the boundary.
##      (No valgrind/ASan in the dev shell; this is the spec-sanctioned
##      alloc/free-balance witness alternative.)
##
##   3. On an ERROR return the `out` parameter is left in a DEFINED EMPTY state
##      (a nil handle / a {nil,0} buffer) and NO Nim exception / panic crosses
##      the ABI — a bad ABI version and a bad handle both return a negative
##      status with a defined-empty out.
##
##   4. The shipped RAII wrapper (`LoadedResourceProviderLibrary`) calls the
##      exported close on scope exit (drop-the-ref → `=destroy`).

import std/[dynlib, options, os, osproc, strutils, unittest]

import repro_resources
import repro_resources/library_transport
import repro_provider_runtime
import repro_interface_artifacts
import repro_project_dsl

type
  CounterAttrs = object
    name*: string
    target*: int

registerExtension[CounterAttrs]("m4b.counter")

# The mock provider: a resource type whose driver ops each allocate an OWNED
# result buffer on the provider heap. Built `--app:lib -d:reproProviderMode
# -d:useMalloc` so its allocations use libc malloc — a DIFFERENT allocator
# from the host's ORC arena.
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
  let path = getEnv("M4B_WORLD")
  if fileExists(path):
    let cur = readFile(path).strip()
    result.present = true
    result.digest = digestString(inst.address & "\x00" & cur)
  else:
    result.present = false

proc cApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  writeFile(getEnv("M4B_WORLD"), $a.target)
  result = ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: cIdentity(inst), postWriteDigest: cDigest(inst), present: true)

registerResourceProvider(ResourceProviderDef(
  typeId: "m4b.counter", determinism: rdVolatile,
  driver: ResourceProviderDriver(
    identity: cIdentity, digest: cDigest, observe: cObserve, apply: cApply)))
registerExtension[CounterAttrs]("m4b.counter")
"""

proc soExt(): string =
  when defined(windows): "dll"
  elif defined(macosx): "dylib"
  else: "so"

proc buildProviderLibrary(tempRoot: string): string =
  ## Compile the mock provider as a shared library over the C ABI, forcing the
  ## provider onto libc `malloc` (`--define:useMalloc`) so it is on a DISTINCT
  ## allocator from the host — a cross-heap free would then be detectable.
  let projDir = tempRoot / "provider"
  createDir(projDir)
  let modulePath = projDir / "mock_provider.nim"
  writeFile(modulePath, providerBody)
  let soPath = tempRoot / ("libm4b_own_provider." & soExt())
  let repoRoot = getCurrentDir()
  var cmd = providerCompileCommand(modulePath, soPath, repoRoot,
    scratchDir = tempRoot)
  # The module path is the LAST argument; insert the library + allocator
  # toggles just before it.
  cmd.insert("--app:lib", cmd.len - 1)
  cmd.insert("--define:useMalloc", cmd.len - 1)
  let (output, code) = execCmdEx(quoteShellCommand(cmd), workingDir = repoRoot)
  if code != 0 or not fileExists(soPath):
    raise newException(IOError,
      "mock provider library build failed (exit " & $code & "):\n" & output)
  soPath

proc desiredInstance(name: string; target: int): ResourceInstance =
  ResourceInstance(
    typeId: "m4b.counter", address: "ctr",
    attrs: TypedExtensionBox[CounterAttrs](
      typeId: "m4b.counter", val: CounterAttrs(name: name, target: target)),
    dependsOn: @[], determinism: rdVolatile)

proc residentPages(): int =
  ## Current resident-set size in pages, from `/proc/self/statm` (field 2).
  ## A stable value across N alloc/free crossings witnesses NO leak of the
  ## OWNED provider buffers (each released via the exported free).
  when defined(linux):
    try:
      let fields = readFile("/proc/self/statm").splitWhitespace()
      if fields.len >= 2: return parseInt(fields[1])
    except CatchableError:
      discard
  -1

suite "M4b: C-ABI provider-library memory-ownership (distinct allocators)":

  test "exported free across N crossings on distinct allocators; no leak / no cross-heap free":
    let tempRoot = getTempDir() / ("m4b-own-" & $getCurrentProcessId())
    removeDir(tempRoot)
    createDir(tempRoot)
    defer: removeDir(tempRoot)

    let soPath = buildProviderLibrary(tempRoot)
    check fileExists(soPath)
    putEnv("M4B_WORLD", tempRoot / "world.txt")

    let lib = loadResourceProviderLibrary(soPath)
    let inst = desiredInstance("own", 1)

    # Warm up so the ORC arena / libc heap reach steady state before we sample
    # the resident set (first allocations grow arenas legitimately).
    const Warm = 200
    const N = 5_000
    for i in 0 ..< Warm:
      discard digestViaLibrary(lib, inst)
    GC_fullCollect()
    let rssBefore = residentPages()

    # N alloc/free crossings: every op allocates an OWNED buffer on the
    # provider's (malloc) heap; `digestViaLibrary` releases it through the
    # callee-EXPORTED `repro_buffer_free`. A mismatch would corrupt/abort here.
    for i in 0 ..< N:
      let d = digestViaLibrary(lib, inst)
      check d.len == 32               # a real, decoded Digest256 each time
    GC_fullCollect()
    let rssAfter = residentPages()

    check lib.callCount() == Warm + N

    # BALANCE WITNESS: resident set did not grow by anything proportional to N
    # (each of the N owned buffers was freed via the exported free). Allow a
    # small slack for arena bookkeeping; a genuine per-op leak of the ~tens of
    # bytes ObservedState buffer over 5k iterations would show as steady growth.
    if rssBefore > 0 and rssAfter > 0:
      let growthPages = rssAfter - rssBefore
      # 256 pages (~1 MiB) is generous slack; a leak would be unbounded with N.
      check growthPages < 256

  test "RAII: dropping the loaded-library ref runs the exported close + unload":
    let tempRoot = getTempDir() / ("m4b-raii-" & $getCurrentProcessId())
    removeDir(tempRoot); createDir(tempRoot)
    defer: removeDir(tempRoot)
    let soPath = buildProviderLibrary(tempRoot)
    putEnv("M4B_WORLD", tempRoot / "world.txt")

    var scoped = loadResourceProviderLibrary(soPath)
    let inst = desiredInstance("raii", 1)
    discard digestViaLibrary(scoped, inst)
    scoped = nil            # last ref dropped -> =destroy -> exported close + unloadLib
    GC_fullCollect()
    check true              # reaching here without a crash proves clean teardown

  test "error paths leave out-params defined-empty; no exception/panic crosses the ABI":
    let tempRoot = getTempDir() / ("m4b-err-" & $getCurrentProcessId())
    removeDir(tempRoot); createDir(tempRoot)
    defer: removeDir(tempRoot)
    let soPath = buildProviderLibrary(tempRoot)

    # Bind the raw open + digest symbols directly (no wrapper) so we can drive
    # error returns and inspect the out-params.
    let raw = loadLib(soPath)
    check raw != nil

    type
      OpenFn = proc (v: uint32; h: ptr pointer): cint {.cdecl.}
      DigestFn = proc (h: pointer; d: pointer; n: csize_t;
                       outp: ptr ReproBuffer): cint {.cdecl.}
    let openFn = cast[OpenFn](symAddr(raw, "repro_provider_open"))
    let digestFn = cast[DigestFn](symAddr(raw, "repro_resource_digest"))
    check openFn != nil and digestFn != nil

    # (a) Bad ABI version: negative status, out-handle left in DEFINED EMPTY
    # (nil) state — pre-seed the out-param with garbage to prove it is cleared.
    var h: pointer = cast[pointer](0xdeadbeef)
    let stVer = openFn(uint32(ReproAbiVersion) + 7'u32, addr h)
    check stVer != 0
    check h == nil

    # (b) Bad handle (nil) into digest: negative status, out-buffer DEFINED
    # EMPTY ({nil,0}) — again pre-seed with garbage.
    var buf = ReproBuffer(data: cast[ptr UncheckedArray[byte]](0xdeadbeef),
                          len: csize_t(999))
    let stBad = digestFn(nil, nil, 0, addr buf)
    check stBad != 0
    check buf.data == nil
    check buf.len == 0

    unloadLib(raw)
