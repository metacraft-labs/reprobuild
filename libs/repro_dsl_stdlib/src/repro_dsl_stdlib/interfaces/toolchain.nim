## Spec-Implementation M3 — ``Toolchain`` cross-cutting interface.
##
## Per Reprobuild-Standard-Library §"Cross-Cutting Interfaces" /
## §"`Toolchain`", a ``Toolchain`` answers "which gcc, which clang,
## which nim is in this build" without recipes having to ask each
## tool's wrapper directly. The interface is vtable-shaped per
## Package-Model §"The framework-recognition interface lives outside
## reprobuild": adapter packages contribute a populated value to the
## active build context, and recipes read through it via
## ``currentBuildContext().toolchain.compile(...)`` and similar.
##
## The M3 methods (``compile``, ``link``, ``archiveExecutable``)
## return a ``BuildAction`` — a lightweight data record that mirrors
## the per-edge information the build engine consumes. The Toolchain
## adapter does not directly enroll into the graph; it returns the
## action and the caller (a helper template, or a recipe author who
## wants explicit control) is responsible for registering the action
## with the engine via the normal ``buildAction(...)`` surface.

import std/[strutils, tables]

type
  BuildAction* = object
    ## Compact action descriptor returned by ``Toolchain`` methods.
    ## Wraps the argv the toolchain proposes plus the explicit input /
    ## output paths so callers can wire the action into the engine via
    ## ``buildAction(...)`` without re-deriving the file boundaries.
    actionId*: string
      ## Stable per-action identifier — used as the cache key prefix.
    argv*: seq[string]
      ## The argv the toolchain wants the engine to execute.
    inputs*: seq[string]
      ## File paths the action reads. Empty when the toolchain can
      ## defer discovery to the engine's monitor-shim path.
    outputs*: seq[string]
      ## File paths the action writes. The toolchain populates this
      ## eagerly because the engine relies on it to wire dependents.
    env*: Table[string, string]
      ## Environment variables the toolchain wants set for the action.

  ToolchainFlags* = object
    ## Default flag bundle a toolchain offers. Typed-tool wrappers
    ## like ``gcc``/``clang`` read this to populate their per-call
    ## flag defaults so a recipe's ``gcc(source = ...)`` respects the
    ## resolved toolchain's defaults without authors threading flags
    ## by hand.
    pic*: bool
      ## True when the toolchain compiles position-independent code.
    debug3*: bool
      ## True when the toolchain emits full ``-g3`` debug info.
    optimization*: string
      ## Optimization level token, e.g. ``"O0"``, ``"O2"``, ``"Os"``.
    languageStandard*: string
      ## Default language standard, e.g. ``"c11"``, ``"c++20"``.

  Toolchain* = ref object of RootObj
    ## Vtable for a toolchain adapter. Stored on
    ## ``PackageBuildState.toolchainSlot`` as a ``RootRef`` per the M3
    ## layering note in ``runtime_core.nim``.
    name*: string
      ## Adapter identity, e.g. ``"gcc-13"``, ``"clang-17"``,
      ## ``"cross-aarch64-linux-gnu"``.
    cCompilerPath*: string
      ## Resolved C compiler binary path. Empty when the adapter
      ## hasn't resolved provisioning yet (defaults answer the binary
      ## name).
    cxxCompilerPath*: string
      ## Resolved C++ compiler binary path.
    linkerPath*: string
      ## Resolved linker binary path. May be the same as
      ## ``cCompilerPath`` when the compiler driver also links.
    defaultFlags*: ToolchainFlags
      ## Per-toolchain flag defaults; typed-tool wrappers consume them
      ## as their fallback flag values.
    compile*: proc(source: string;
                   output: string;
                   flags: seq[string]): BuildAction
      ## Build the compile action for a single translation unit.
    link*: proc(objects: seq[string];
                output: string;
                flags: seq[string]): BuildAction
      ## Build the link action that produces ``output`` from
      ## ``objects``. ``output`` is treated as an executable; static-
      ## library and shared-library variants land in M5 alongside
      ## cross-compilation.
    archiveExecutable*: proc(binary: string; archive: string): BuildAction
      ## Build the action that wraps a built executable into the
      ## adapter's archive convention (e.g. tarball, zip). The default
      ## adapters supply a thin ``cp`` proc; the cross-compilation
      ## adapter swaps in something sysroot-aware.

proc newToolchain*(
    name: string;
    cCompilerPath: string;
    cxxCompilerPath: string;
    linkerPath: string;
    defaultFlags: ToolchainFlags;
    compile: proc(source: string; output: string;
                  flags: seq[string]): BuildAction;
    link: proc(objects: seq[string]; output: string;
               flags: seq[string]): BuildAction;
    archiveExecutable: proc(binary: string; archive: string): BuildAction
    ): Toolchain =
  ## Builder for a fully populated ``Toolchain``. Adapter packages
  ## invoke this rather than constructing the object literally so the
  ## vtable can grow additively at minor versions without breaking
  ## constructor sites.
  Toolchain(
    name: name,
    cCompilerPath: cCompilerPath,
    cxxCompilerPath: cxxCompilerPath,
    linkerPath: linkerPath,
    defaultFlags: defaultFlags,
    compile: compile,
    link: link,
    archiveExecutable: archiveExecutable)

proc validate*(t: Toolchain) =
  ## Assert every required field is populated. The build context wires
  ## the slot through this check so a malformed adapter trips at slot
  ## installation time, not at the first ``compile`` call.
  doAssert t != nil,
    "Toolchain is nil — the active build context's toolchain slot " &
    "was never populated"
  doAssert t.name.len > 0,
    "Toolchain.name is empty — every adapter must set its identity"
  doAssert t.compile != nil,
    "Toolchain.compile is nil — adapter '" & t.name & "' is incomplete"
  doAssert t.link != nil,
    "Toolchain.link is nil — adapter '" & t.name & "' is incomplete"
  doAssert t.archiveExecutable != nil,
    "Toolchain.archiveExecutable is nil — adapter '" & t.name &
      "' is incomplete"

proc render*(action: BuildAction): string =
  ## Diagnostic dump used by ``repro why`` and the test surface to
  ## present the action without losing its structural form. Format:
  ## ``"<actionId>: <argv...>"``.
  action.actionId & ": " & action.argv.join(" ")
