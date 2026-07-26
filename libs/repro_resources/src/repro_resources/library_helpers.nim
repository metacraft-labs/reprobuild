## Typed-Extension-Interfaces M4 — the Nim **helper module** for the C-ABI
## provider-library transport (Low-Level-Provider-Protocol.md §6.4).
##
## This is the ONE import a Nim provider-library or consumer author uses. It
## presents the typed, RAII-safe wrappers over the type-erased low-level ABI
## (`library_abi.nim`) so neither side touches raw `ReproProviderHandle` /
## `ReproBuffer` pointers or the exported free by hand. The equivalent for
## non-Nim authors is the C header `c/repro_provider_abi.h` (+ the C++
## reference wrapper `c/repro_provider_abi.hpp`).
##
## ===========================================================================
## CONSUME side (engine / any host that links a provider `.so`)
## ===========================================================================
## Use the move-only RAII handle `LoadedResourceProviderLibrary` and the typed
## ops re-exported here from `library_transport.nim`:
##
## .. code-block:: nim
##   import repro_resources/library_helpers
##
##   let lib = loadResourceProviderLibrary("./libmyprovider.so")
##   # `lib` is a ref whose `=destroy` calls the callee-exported
##   # `repro_provider_close` + unloads the `.so` — a leaked dlopen / provider
##   # handle is hard to write (§6.4). No manual close.
##   let obs = observeViaLibrary(lib, inst, prior)
##   let binding = applyViaLibrary(lib, inst, action, obs)
##   # `lib` goes out of scope -> =destroy -> exported close + unloadLib.
##
## The typed ops (`digestViaLibrary` / `observeViaLibrary` / `applyViaLibrary`)
## encode the inputs, cross them as borrowed `(ptr,len)` buffers, and release
## every OWNED result buffer through the callee-exported `repro_buffer_free`
## internally (`takeBuffer`) — the ownership contract (§6.2) is upheld by the
## wrapper, not the caller.
##
## ===========================================================================
## PRODUCE side (a Nim provider compiled as a linkable library)
## ===========================================================================
## A Nim provider author does NOT hand-write any `{.exportc, cdecl.}` entry
## points. They register a driver exactly as for the in-process / session
## transports, then compile the module `--app:lib --define:reproProviderMode`.
## The `reproProviderMode` block in `library_abi.nim` then emits the fixed
## cdecl symbol set (`repro_provider_open` / `repro_resource_{digest,observe,
## apply}` / `repro_buffer_free` / `repro_provider_close` / …) which dispatch
## into the registered driver:
##
## .. code-block:: nim
##   # myprovider.nim  — build: nim c --app:lib -d:reproProviderMode myprovider
##   import repro_resources
##   registerResourceProvider(ResourceProviderDef(
##     typeId: "acme.widget", determinism: rdVolatile,
##     driver: ResourceProviderDriver(identity: …, digest: …,
##                                    observe: …, apply: …)))
##   registerExtension[WidgetAttrs]("acme.widget")
##
## So the "producer helper" is the `reproProviderMode` compile mode plus the
## ordinary registry — no per-provider ABI boilerplate. This module re-exports
## the ABI vocabulary (`ReproStatus`, `ReproAbiVersion`, the `reproErr*`
## codes, the `Sym*` symbol names) so a producer that needs to introspect the
## contract, or a consumer that binds a subset by hand, has it in one place.

import repro_resources/library_abi
import repro_resources/library_transport

export library_abi
export library_transport
