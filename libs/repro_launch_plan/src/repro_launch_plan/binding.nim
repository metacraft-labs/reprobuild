## Pure binding-decision algorithm (M57 spec §"Binding Decision Algorithm")
## and the deterministic POSIX launcher-script generator used by Linux
## strategy 3 and macOS strategy 3.
##
## The binding decision is platform-driven but EVALUATED ON THE HOST
## that emits the plan — it does NOT depend on the platform the launcher
## runs on. The launch plan records the chosen strategy so a downstream
## activation step can materialize the right artifact deterministically.

import ./types

type
  BindingInput* = object
    ## Inputs the realization step hands to `decideBinding`. They are
    ## kept small because none of them are dynamic — they all come from
    ## the adapter receipt and the realized prefix layout.
    platform*: string                ## "linux" | "macos" | "windows"
    realizedPrefix*: string          ## absolute path on disk
    executablePath*: string          ## absolute path inside realizedPrefix
    dependencyDirs*: seq[string]     ## absolute paths to dep libdirs
    canRewriteBinary*: bool          ## adapter-provided: does the binary
                                     ## tolerate `RUNPATH`/`LC_RPATH`
                                     ## rewriting (Reprobuild-built or
                                     ## tarball-extracted binaries can;
                                     ## code-signed macOS binaries cannot)
    canUseOriginRelative*: bool      ## true when the realized prefix
                                     ## exposes a stable adjacency layout
                                     ## (typical for a projected runtime
                                     ## image)
    isAppLocalLayout*: bool          ## Windows only: every dep DLL is
                                     ## already next to the executable
    hasProjectedImage*: bool         ## Windows strategy 3 / macOS strat 2

  BindingDecision* = object
    binding*: LaunchPlanBindingKind
    runtimeLibraryDirs*: seq[string] ## what the launcher/loader should
                                     ## consult — EXACT, no widening
    notes*: string                   ## free-form explanation surfaced to
                                     ## `repro launch-plan show`

proc decideBinding*(inp: BindingInput): BindingDecision =
  ## Implements the per-platform preference order from the spec. The
  ## result is deterministic in its inputs — content-addressing depends
  ## on this property.
  case inp.platform
  of "linux":
    if inp.canRewriteBinary:
      return BindingDecision(binding: lbkLinuxRunpathExact,
        runtimeLibraryDirs: inp.dependencyDirs,
        notes: "strategy 1: embedded RUNPATH at exact dep dirs")
    if inp.canUseOriginRelative:
      return BindingDecision(binding: lbkLinuxOriginRelative,
        runtimeLibraryDirs: @["$ORIGIN"],
        notes: "strategy 2: $ORIGIN-relative RUNPATH (projected layout)")
    return BindingDecision(binding: lbkLinuxScript,
      runtimeLibraryDirs: inp.dependencyDirs,
      notes: "strategy 3: POSIX launcher script (fallback)")
  of "macos":
    if inp.canRewriteBinary:
      return BindingDecision(binding: lbkMacosRpathRewrite,
        runtimeLibraryDirs: inp.dependencyDirs,
        notes: "strategy 1: @rpath + install-name rewriting")
    if inp.canUseOriginRelative:
      return BindingDecision(binding: lbkMacosLoaderPath,
        runtimeLibraryDirs: @["@loader_path"],
        notes: "strategy 2: @loader_path inside projection")
    return BindingDecision(binding: lbkMacosScript,
      runtimeLibraryDirs: inp.dependencyDirs,
      notes: "strategy 3: bash launcher (ambient DYLD_LIBRARY_PATH)")
  of "windows":
    if not inp.isAppLocalLayout and not inp.hasProjectedImage:
      return BindingDecision(binding: lbkWindowsLauncher,
        runtimeLibraryDirs: inp.dependencyDirs,
        notes: "strategy 1: native PE launcher + AddDllDirectory per dep")
    if inp.isAppLocalLayout:
      return BindingDecision(binding: lbkWindowsAppLocal,
        runtimeLibraryDirs: @[],
        notes: "strategy 2: app-local DLL layout (no extra search dirs)")
    return BindingDecision(binding: lbkWindowsProjection,
      runtimeLibraryDirs: inp.dependencyDirs,
      notes: "strategy 3: projected runtime image")
  else:
    raise newException(ValueError,
      "unknown platform for binding decision: " & inp.platform)

# ---------------------------------------------------------------------------
# POSIX launcher script generator (strategy 3 on Linux and macOS)
# ---------------------------------------------------------------------------

proc shellEscape(s: string): string =
  ## Single-quote a string for `sh`. Inside single quotes the only
  ## metacharacter is `'` itself, which we close-quote, escape, and
  ## reopen-quote. This produces a byte-stable output for any input.
  result = "'"
  for ch in s:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

proc generatePosixLauncherScript*(plan: LaunchPlan; pathVar: string): string =
  ## Generate the strategy-3 launcher script bytes deterministically.
  ## Two identical `LaunchPlan` records produce byte-identical scripts.
  ## `pathVar` is `LD_LIBRARY_PATH` on Linux and `DYLD_LIBRARY_PATH` on
  ## macOS — the caller picks based on the chosen binding.
  doAssert isPosixScriptBinding(plan.binding),
    "generatePosixLauncherScript: plan binding is " & $plan.binding
  result = LaunchScriptMagicPosix & "\n"
  result.add("#!/bin/sh\n")
  result.add("# command: " & plan.exportedCommand & "\n")
  result.add("# realizedPrefix: " & plan.realizedPrefix & "\n")
  result.add("# strategy: " & $plan.binding & "\n")
  # Prepend the exact dependency dirs to the path variable. The script
  # MUST NOT widen the search — every dir comes straight from
  # plan.runtimeLibraryDirs in order, joined with ':'.
  if plan.runtimeLibraryDirs.len > 0:
    var joined = ""
    for i, d in plan.runtimeLibraryDirs:
      if i > 0: joined.add(':')
      joined.add(d)
    result.add(pathVar & "=" & shellEscape(joined) & "${" & pathVar & ":+:${" &
      pathVar & "}}\n")
    result.add("export " & pathVar & "\n")
  for eb in plan.environmentBindings:
    case eb.kind
    of ebkSet:
      result.add(eb.name & "=" & shellEscape(eb.value) & "\n")
      result.add("export " & eb.name & "\n")
    of ebkPrepend:
      result.add(eb.name & "=" & shellEscape(eb.value) & "${" & eb.name &
        ":+:${" & eb.name & "}}\n")
      result.add("export " & eb.name & "\n")
    of ebkAppend:
      result.add(eb.name & "=${" & eb.name & ":+${" & eb.name & "}:}" &
        shellEscape(eb.value) & "\n")
      result.add("export " & eb.name & "\n")
    of ebkUnset:
      result.add("unset " & eb.name & "\n")
  if plan.hasWorkingDirectory:
    result.add("cd " & shellEscape(plan.workingDirectory) & "\n")
  # Build the static-arg vector; passthrough is "$@".
  var execLine = "exec " & shellEscape(plan.executablePath)
  for arg in plan.arguments:
    execLine.add(' ')
    execLine.add(shellEscape(arg))
  execLine.add(" \"$@\"\n")
  result.add(execLine)
