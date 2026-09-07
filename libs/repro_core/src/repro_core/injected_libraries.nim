## Name the library we inject when a process we started dies in the loader.
##
## Automatic monitoring puts a library into every process a build starts, with
## `LD_PRELOAD` on Linux and `DYLD_INSERT_LIBRARIES` on macOS. That library is a
## guest in a process nobody here built, and when the two disagree about
## anything the loader cares about — a C runtime's symbol versions, a missing
## dependency, an unresolved symbol — the process dies *before its first
## instruction*, and the diagnostic the operating system prints names the two
## libraries it was trying to reconcile. Neither of them is the injected one.
##
## What that looks like in practice, and why it is worth a whole module: a
## build died with
##
##   …/bash: …/libc.so.6: version `GLIBC_ABI_DT_X86_64_PLT' not found
##     (required by …/libm.so.6)
##   Error: execution of an external program failed: '…/bin/gcc -c …'
##
## Three loader lines and a compiler command. Everything named is correct and
## none of it is the cause: the process was fine until something was injected
## into it. There is no route from that text to "an injected library", let
## alone to which one — and the only party that knows a library was injected at
## all is us.
##
## So: when a child fails with a loader diagnostic AND we are injecting, append
## a sentence saying so and naming the library. Deliberately additive to the
## existing message rather than a replacement — the loader's own text is the
## evidence, and a reader who already knows what it means should not have to
## read past a paragraph to reach it.
##
## Both halves of the condition are required, and each rules out a different
## wrong answer. Without the loader needles this would blame the injected
## library for every compile error there is. Without the injection check it
## would blame it on a host that is not injecting anything, where a genuine
## loader problem in the project's own toolchain is exactly what the message
## says it is.

import std/[os, strutils]

const
  LoaderFailureNeedles = [
    # A satellite library requires a symbol version the process's C runtime
    # does not define. This is what a mixed C runtime looks like, and it is
    # the failure this module was written for.
    "version `GLIBC_",
    # The loader could not find a dependency at all.
    "error while loading shared libraries",
    "cannot open shared object file",
    # The libraries loaded, but one of them wanted something another does not
    # export — the same disagreement, one layer later.
    "symbol lookup error",
    # macOS wording for the same two conditions.
    "dyld: Library not loaded",
    "dyld[",
  ]

  InjectionVariables = [
    "LD_PRELOAD",
    "DYLD_INSERT_LIBRARIES",
  ]

proc looksLikeLoaderFailure*(output: string): bool =
  ## Whether a child's combined output carries a dynamic-loader diagnostic.
  for needle in LoaderFailureNeedles:
    if needle in output:
      return true
  false

proc injectedLibraries*(): seq[tuple[variable, value: string]] =
  ## The libraries this process is injecting into everything it starts, read
  ## from the environment rather than from what we believe we configured: the
  ## environment is what the child will actually be handed, including anything
  ## inherited from further out.
  for variable in InjectionVariables:
    let value = getEnv(variable)
    if value.len > 0:
      result.add((variable, value))

const InjectionVariableForHost* =
  when defined(macosx): "DYLD_INSERT_LIBRARIES"
  else: "LD_PRELOAD"

proc injectedLibraryNote*(output: string;
                          alsoInjected: openArray[string] = []): string =
  ## The sentence to append to a failed child's report. Empty when the child
  ## did not fail in the loader, or when nothing is being injected — in both
  ## cases there is nothing here to say and saying it anyway would send the
  ## reader after the wrong thing.
  ##
  ## `alsoInjected` exists because the injection is not always visible in OUR
  ## environment. Where a build is monitored from the outside, the variable is
  ## in this process's environment and every child inherits it — that is the
  ## `injectedLibraries()` case, and it covers the interface and provider
  ## compiles, which run in-process. Where the engine itself starts a monitored
  ## action, it composes the variable for THAT CHILD ONLY and nothing about it
  ## appears here. The caller knows which library it configured; without this
  ## parameter the one place with the most context would be the one place that
  ## says nothing.
  if not looksLikeLoaderFailure(output):
    return ""
  var injected = injectedLibraries()
  for path in alsoInjected:
    if path.len == 0:
      continue
    var seen = false
    for (_, value) in injected:
      if value == path or path in value:
        seen = true
        break
    if not seen:
      injected.add((InjectionVariableForHost, path))
  if injected.len == 0:
    return ""
  result = "\n" &
    "note: the failure above came from the dynamic loader, and this build is\n" &
    "      injecting a library into every process it starts:\n"
  for (variable, value) in injected:
    result.add("        " & variable & "=" & value & "\n")
  result.add(
    "      An injected library is loaded into a process built by somebody\n" &
    "      else, so it must take its C runtime from that process rather than\n" &
    "      bring one. If it carries a runtime of its own (a DT_RUNPATH naming\n" &
    "      a directory that holds libc and its satellites), the loader will\n" &
    "      mix the two and the process dies before it starts — which is what\n" &
    "      the lines above are, and why none of them mentions this library.\n" &
    "      Confirm it: `patchelf --print-rpath <library>` must name no\n" &
    "      directory holding libc.so.6 and its satellites. If it does, rebuild\n" &
    "      the library so it imposes nothing — see\n" &
    "      scripts/lib/preloaded_shim_loader.sh, which is the same check the\n" &
    "      build's publish step and `just lint` already apply.\n")
