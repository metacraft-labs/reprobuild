## Typed-Extension-Interfaces M4c — the nimRtl Nim-native FAST PATH for the
## resource-reconcile leaf ops (Typed-Extension-Interfaces §4.2b/§4.4,
## Low-Level-Provider-Protocol.md §6, note §6.2 that the Nim fast path is an
## optimization ABOVE the C-ABI contract).
##
## When the host + the Nim provider library are BOTH built
## ``-d:useNimRtl -d:reproNimRtlShared`` against ONE shared ``nimrtl`` (matched
## Nim version + ORC), they share one GC / heap / type machinery, so the
## boundary passes LIVE Nim typed values directly (``ResourceInstance`` /
## ``ObservedState`` / ``ResourceBinding``) with NO ``encode*`` marshal, NO
## ``(ptr,len)`` buffer, NO ``repro_buffer_free``. Without nimRtl the SAME
## provider falls back to the C-ABI buffer path (M4a) — and the two builds are
## DISTINCT action-key cache entries (the RTL mode is a semantic compile
## option, §4.4).
##
## This test can NOT run the direct path from THIS binary (the unittest process
## is not itself a nimRtl-shared host). So, exactly like M4a compiles the mock
## provider ``.so``, it ALSO compiles:
##   * ONE shared ``nimrtl`` (``-d:createNimRtl --app:lib``),
##   * a nimRtl-shared provider ``.so`` (``-d:reproNimRtlShared -d:useNimRtl``),
##   * a standalone C-ABI provider ``.so`` (``--app:lib`` only),
##   * a nimRtl-shared HOST DRIVER (``-d:reproNimRtlShared -d:useNimRtl``) that
##     dlopens a provider ``.so``, reconciles a resource, and prints witnesses.
## The host driver + both provider ``.so``s link the SAME ``nimrtl``.
##
## WITNESSES the driver prints (asserted here):
##   * direct-path run: ``callCount`` > 0 while ``marshalCount`` == 0
##     (the driver op ran on a LIVE typed value — NO encode/decode marshal),
##     and ``usesNimRtl`` is true.
##   * C-ABI-fallback run (same driver, standalone ``.so``): ``marshalCount``
##     > 0 and ``usesNimRtl`` is false — the buffer path.
## Plus: the two provider builds have DISTINCT provider-library action keys.

import std/[options, os, osproc, strutils, tables, unittest]

import repro_interface_artifacts
import repro_hash

proc soExt(): string =
  when defined(windows): "dll"
  elif defined(macosx): "dylib"
  else: "so"

# ---------------------------------------------------------------------------
# The SHARED attrs-type module, compiled into BOTH the provider .so and the
# host driver.
#
# The direct no-marshal path passes a LIVE Nim ``TypedExtensionBox[CounterAttrs]``
# across the boundary, so the two sides must agree on the TYPE, not merely on
# its field layout. ORC's runtime type identity is derived from the mangled type
# name, so two structurally identical ``CounterAttrs`` declarations — one in the
# host, one in the provider — are DISTINCT types: the provider's
# ``TypedExtensionBox[CounterAttrs](inst.attrs)`` conversion then raises
# ``ObjectConversionDefect`` even though host and provider share one nimRtl.
# Hoisting the declaration into one module that both builds ``--path`` in
# mirrors the real shape (the defining repo publishes the attrs type; provider
# and consumer both compile against that one declaration) and is what makes the
# live-value crossing sound. The C-ABI fallback path does not need this — it
# goes through the ``encode*`` codec keyed by ``typeId`` — but both provider
# builds come from the same source, so it uses the shared module too.
# ---------------------------------------------------------------------------
const sharedTypesBody = """
import repro_project_dsl

type
  CounterAttrs* = object
    name*: string
    target*: int

registerExtension[CounterAttrs]("m4c.counter")
"""

# ---------------------------------------------------------------------------
# The mock provider source (a live-value counter, same shape as M4a). Compiled
# --app:lib it exports the C ABI; with -d:reproNimRtlShared it ADDITIONALLY
# exports the *_direct no-marshal entry points + the SymRtlProbe presence
# symbol from library_abi.nim.
# ---------------------------------------------------------------------------
const providerBody = """
import std/[options, os, strutils]
import repro_resources
import repro_project_dsl
import m4c_shared_types

proc cIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  "counter:" & a.name

proc cDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  digestString(inst.address & "\x00" & $a.target)

proc cObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let path = getEnv("M4C_WORLD")
  if fileExists(path):
    let cur = readFile(path).strip()
    result.present = true
    result.digest = digestString(inst.address & "\x00" & cur)
  else:
    result.present = false

proc cApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[CounterAttrs](inst.attrs).val
  writeFile(getEnv("M4C_WORLD"), $a.target)
  result = ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: cIdentity(inst), postWriteDigest: cDigest(inst), present: true)

registerResourceProvider(ResourceProviderDef(
  typeId: "m4c.counter", determinism: rdVolatile,
  driver: ResourceProviderDriver(
    identity: cIdentity, digest: cDigest, observe: cObserve, apply: cApply)))
"""

# ---------------------------------------------------------------------------
# The nimRtl-shared HOST DRIVER source. Built -d:reproNimRtlShared -d:useNimRtl
# against the SAME nimrtl as the provider .so, so the transport binds the
# *_direct entries and reconcile takes the no-marshal path. It prints the
# witnesses as parseable KEY=VALUE lines.
# ---------------------------------------------------------------------------
const hostDriverBody = """
import std/[options, os, strutils]
import repro_resources
import repro_resources/library_transport
import repro_project_dsl
import m4c_shared_types

proc desired(name: string; target: int): ResourceInstance =
  ResourceInstance(
    typeId: "m4c.counter", address: "ctr",
    attrs: TypedExtensionBox[CounterAttrs](
      typeId: "m4c.counter", val: CounterAttrs(name: name, target: target)),
    dependsOn: @[], determinism: rdVolatile)

# The provider .so path arrives through the environment, NOT through argv.
# This driver is built -d:useNimRtl, and std/cmdline reads the `importc`
# globals `cmdCount`/`cmdLine`, which the Nim runtime only populates from a
# real program entry point -- Nim documents that "on Posix, there is no
# portable way to get the command line from a DLL". Under -d:useNimRtl those
# globals stay at zero, so `paramStr(1)` raises IndexDefect. -d:useNimRtl is
# the feature under test here and must not be dropped, so we mirror the
# M4C_WORLD env-var handoff below instead.
let soPath = getEnv("M4C_PROVIDER_SO")
if soPath.len == 0:
  quit("M4C_PROVIDER_SO is unset: the host driver has no provider .so to dlopen", 2)
let lib = loadResourceProviderLibrary(soPath)
echo "USES_NIMRTL=", lib.usesNimRtl()

let inst = desired("hits", 7)
# A full reconcile leaf sequence: digest + observe + apply. Each goes through
# digest/observe/applyViaLibrary, which auto-route to the *_direct no-marshal
# path when usesNimRtl, else the C-ABI buffer path.
let d = digestViaLibrary(lib, inst)
let obs = observeViaLibrary(lib, inst, none(ResourceBinding))
let binding = applyViaLibrary(lib, inst, rakCreate, obs)
echo "RESOURCE_ID=", binding.resourceId
echo "WORLD=", readFile(getEnv("M4C_WORLD")).strip()
echo "CALL_COUNT=", lib.callCount()
echo "MARSHAL_COUNT=", lib.marshalCount()
"""

proc writeSource(dir, name, body: string): string =
  createDir(dir)
  result = dir / name
  writeFile(result, body)

proc selfBindFlags(): seq[string] =
  ## Force every shared object built here to bind its OWN function definitions
  ## internally instead of letting the process-wide lookup scope hijack them.
  ##
  ## Nim emits a library constructor that calls ``NimMainInit`` (module init),
  ## and it exports ``NimMain`` / ``NimMainInit`` with default visibility. On
  ## ELF, the executable and its already-loaded dependencies outrank a
  ## ``dlopen``ed object in the global lookup scope, so with an unqualified
  ## build we measured (``LD_DEBUG=bindings``):
  ##
  ##   * ``libnimrtl.so``'s internal ``NimMain`` bound to the HOST DRIVER
  ##     EXECUTABLE's ``NimMain`` -- the driver's whole module body, dlopen and
  ##     reconcile included, ran twice.
  ##   * the provider ``.so``'s constructor call to ``NimMainInit`` bound to
  ##     ``libnimrtl.so``'s ``NimMainInit`` -- so the provider's OWN modules
  ##     never initialised, ``registerResourceProvider`` never ran, and the ops
  ##     failed with ``no resource provider registered for typeId
  ##     'm4c.counter'`` (C-ABI path) or segfaulted (direct path).
  ##
  ## ``-Bsymbolic-functions`` only redirects references a shared object makes to
  ## functions it defines ITSELF; calls from the host into ``libnimrtl`` and from
  ## the provider into ``libnimrtl`` are unaffected, so the ONE-shared-nimRtl
  ## premise under test is preserved. Mach-O (two-level namespace) and PE
  ## already bind per-module, so the flag is ELF-only.
  when defined(macosx) or defined(windows): @[]
  else: @["--passL:-Wl,-Bsymbolic-functions"]

proc locateNimrtlSource(): string =
  ## Find ``lib/nimrtl.nim`` in the active Nim toolchain via ``nim dump``.
  let (dump, _) = execCmdEx("nim dump 2>&1")
  for line in dump.splitLines():
    let p = line.strip()
    if p.endsWith("lib") and dirExists(p) and fileExists(p / "nimrtl.nim"):
      return p / "nimrtl.nim"
  # Fallback: search the lib-path lines for any nimrtl.nim.
  for line in dump.splitLines():
    let p = line.strip()
    if dirExists(p) and fileExists(p / "nimrtl.nim"):
      return p / "nimrtl.nim"
  raise newException(IOError, "could not locate nimrtl.nim in the toolchain")

suite "M4c: resource reconcile over the nimRtl Nim-native fast path (no marshal)":

  test "t_provider_library_nimrtl_direct_call_no_marshal":
    let repoRoot = getCurrentDir()
    let tempRoot = getTempDir() / ("m4c-" & $getCurrentProcessId())
    removeDir(tempRoot)
    createDir(tempRoot)
    defer: removeDir(tempRoot)

    let modulePath = writeSource(tempRoot / "provider", "mock_provider.nim",
      providerBody)
    # ONE declaration of the attrs type, compiled into the provider .so AND the
    # host driver, so the live typed value the direct path passes has the same
    # ORC type identity on both sides (see ``sharedTypesBody``).
    let sharedDir = tempRoot / "shared"
    discard writeSource(sharedDir, "m4c_shared_types.nim", sharedTypesBody)
    let sharedPath = "--path:" & sharedDir

    # ── RTL-mode IN THE ACTION KEY ─────────────────────────────────────────
    # The nimRtl-shared and standalone C-ABI library builds are DISTINCT
    # action-key cache entries (§4.4) — the RTL-mode --defines are semantic
    # compile options that flow into the ProviderArtifactId.
    let ifaceFp = default(ContentDigest)
    let keyShared = providerLibraryCompileActionKey(modulePath,
      tempRoot / "shared.so", ifaceFp, rtlNimRtlShared, repoRoot, tempRoot)
    let keyStandalone = providerLibraryCompileActionKey(modulePath,
      tempRoot / "standalone.so", ifaceFp, rtlStandaloneCAbi, repoRoot, tempRoot)
    check keyShared != keyStandalone

    let nimBin = providerLibraryCompileCommand(modulePath, tempRoot / "x.so",
      rtlNimRtlShared, repoRoot, tempRoot)[0]  # the resolved nim compiler path

    # ── The nimRtl-shared END-TO-END build (nimrtl + provider .so + host) ──
    # HISTORY: under Nim 2.2.4 this toolchain hit an UPSTREAM nimRtl bug —
    # `std/streams` (which the `reproProviderMode` closure imports via
    # `repro_project_dsl`) failed to compile under `-d:useNimRtl` because
    # `ssReadDataStr`'s inferred `raises: []` effect mismatched the
    # `readDataStrImpl` field type (streams.nim ~1316, "raise effects
    # differ"). The test used to sniff that message out of the compiler
    # output and fall back to `check standaloneSo.len > 0` — a near-vacuous
    # assertion that would have reported a green direct-path gate while the
    # direct path was never built, let alone exercised.
    #
    # That fallback is GONE. Every build step below raises with the full
    # compiler output on failure, so the direct-call witnesses at the end of
    # this test always run. If a toolchain ever reintroduces the streams /
    # nimRtl effect mismatch (or any other `-d:useNimRtl` breakage), this
    # test FAILS and prints the exact compiler diagnostic — strictly more
    # informative than a hard-coded toolchain-version assertion, and it
    # cannot silently degrade to "the standalone .so exists".
    let nimrtlSo = tempRoot / ("libnimrtl." & soExt())
    var sharedSo, standaloneSo, hostBin = ""

    proc buildStandaloneProvider(): string =
      ## The C-ABI standalone provider .so always builds (no useNimRtl).
      result = tempRoot / ("libstandalone." & soExt())
      var cmd = providerLibraryCompileCommand(modulePath, result,
        rtlStandaloneCAbi, repoRoot, tempRoot)
      # Flags go BEFORE the trailing module path (anything after it is a run arg).
      for flag in selfBindFlags() & @[sharedPath]:
        cmd.insert(flag, cmd.len - 1)
      let (o, c) = execCmdEx(quoteShellCommand(cmd), workingDir = repoRoot)
      if c != 0 or not fileExists(result):
        raise newException(IOError, "standalone provider build failed (" & $c &
          "):\n" & o)

    standaloneSo = buildStandaloneProvider()

    block:
      # 1) the ONE shared nimrtl
      let cmd = @[nimBin, "c", "-d:createNimRtl", "-d:release", "--mm:orc",
        "--app:lib"] & selfBindFlags() &
        @["--out:" & nimrtlSo, locateNimrtlSource()]
      let (o, c) = execCmdEx(quoteShellCommand(cmd), workingDir = repoRoot)
      if c != 0 or not fileExists(nimrtlSo):
        raise newException(IOError, "nimrtl build failed (" & $c & "):\n" & o)

      # 2) the nimRtl-shared provider .so (fast-path surface)
      let so = tempRoot / ("libshared." & soExt())
      var pcmd = providerLibraryCompileCommand(modulePath, so,
        rtlNimRtlShared, repoRoot, tempRoot)
      pcmd.insert("--passL:-L" & tempRoot, pcmd.len - 1)
      pcmd.insert("--passL:-lnimrtl", pcmd.len - 1)
      pcmd.insert("--passL:-Wl,-rpath," & tempRoot, pcmd.len - 1)
      for flag in selfBindFlags() & @[sharedPath]:
        pcmd.insert(flag, pcmd.len - 1)
      let (po, pc) = execCmdEx(quoteShellCommand(pcmd), workingDir = repoRoot)
      if pc != 0 or not fileExists(so):
        raise newException(IOError, "nimRtl provider build failed (" & $pc &
          "):\n" & po)
      sharedSo = so

      # 3) the nimRtl-shared HOST DRIVER (dlopens a provider .so, reconciles)
      let hostSrc = writeSource(tempRoot / "host", "host_driver.nim",
        hostDriverBody)
      let hb = tempRoot / "host_driver"
      var hcmd = @[nimBin, "c", "-d:release", "--mm:orc",
        "-d:reproNimRtlShared", "-d:useNimRtl",
        "--passL:-L" & tempRoot, "--passL:-lnimrtl",
        "--passL:-Wl,-rpath," & tempRoot,
        "--path:" & (tempRoot / "host"), sharedPath]
      hcmd.add(consumerCompilePathFlags(repoRoot))
      hcmd.add(@["--out:" & hb, hostSrc])
      let (ho, hc) = execCmdEx(quoteShellCommand(hcmd), workingDir = repoRoot)
      if hc != 0 or not fileExists(hb):
        raise newException(IOError, "host driver build failed (" & $hc &
          "):\n" & ho)
      hostBin = hb

    # Run helper: the driver, given a provider .so, prints KEY=VALUE witnesses.
    proc runDriver(so: string): Table[string, string] =
      let worldPath = tempRoot / ("world-" & extractFilename(so) & ".txt")
      putEnv("M4C_WORLD", worldPath)
      # The driver is a -d:useNimRtl binary, so argv is not readable from it
      # (std/cmdline's cmdCount/cmdLine stay unpopulated -- see the note in
      # hostDriverBody). Hand the provider .so path over via the environment,
      # the same channel as M4C_WORLD.
      putEnv("M4C_PROVIDER_SO", so)
      let ld = tempRoot & (if existsEnv("LD_LIBRARY_PATH"):
        ":" & getEnv("LD_LIBRARY_PATH") else: "")
      putEnv("LD_LIBRARY_PATH", ld)
      let (o, c) = execCmdEx(quoteShellCommand(@[hostBin]),
        workingDir = tempRoot)
      if c != 0:
        raise newException(IOError, "driver run on " & so & " failed (" & $c &
          "):\n" & o)
      result = initTable[string, string]()
      for line in o.splitLines():
        let kv = line.split('=', 1)
        if kv.len == 2: result[kv[0]] = kv[1]

    # ── DIRECT PATH: nimRtl-shared provider, no marshal ────────────────────
    let direct = runDriver(sharedSo)
    check direct["USES_NIMRTL"] == "true"
    check direct["RESOURCE_ID"] == "counter:hits"
    check direct["WORLD"] == "7"
    # NO-MARSHAL WITNESS: the driver ops ran (callCount>0) but performed ZERO
    # C-ABI encode/decode marshals — the live typed values crossed directly.
    check parseInt(direct["CALL_COUNT"]) > 0
    check direct["MARSHAL_COUNT"] == "0"

    # ── FALLBACK: standalone C-ABI provider, buffer path ───────────────────
    let fallback = runDriver(standaloneSo)
    check fallback["USES_NIMRTL"] == "false"
    check fallback["RESOURCE_ID"] == "counter:hits"
    check fallback["WORLD"] == "7"
    # The SAME provider logic, but over the C-ABI buffer path: marshals > 0.
    check parseInt(fallback["MARSHAL_COUNT"]) > 0
