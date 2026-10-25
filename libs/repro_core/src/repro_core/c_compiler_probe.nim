## Shared capability payload and diagnostic for Reprobuild's own C compiles.
## Process execution and scratch/cache ownership stay with the caller: recipe
## compilation and monitored profile compilation have different execution seams.
import std/[os, strutils]
from ./c_compiler import bootstrapSdkRootEnv, cCompilerOverrideRemedy

type
  CCompilerProbe* = object
    compiler*: string
    usable*: bool
    detail*: string
      ## Why the probe failed (the compiler's own output, or the reason it
      ## could not run). Empty when ``usable``.

const
  cCompilerProbeSource* = """
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
/* Nim's std/sysrand includes this SDK framework header on Darwin. GCC can
   compile the standard headers and still fail here, so test both. */
#include <Security/SecRandom.h>
#endif
/* Nim generates C for THIS host's pointer width. A compiler for another
   target (e.g. an i386 gcc on an x86_64 host) links garbage, so refuse it
   here, where the message can say so, rather than three layers later. */
typedef char repro_probe_pointer_width[
  (sizeof(void *) == REPRO_PROBE_POINTER_BYTES) ? 1 : -1];
int repro_probe(void) { return (int)(sizeof(size_t) + strlen("ok")); }
"""

proc cCompilerProbeArgv*(cc, source, output: string;
                         extraArgs: seq[string] = @[]): seq[string] =
  ## Test the same headers and host pointer width in both compile paths.
  @[cc] & extraArgs & @["-c",
    "-DREPRO_PROBE_POINTER_BYTES=" & $sizeof(pointer), source, "-o", output]

proc cCompilerUnusableMessageFor*(probe: CCompilerProbe; origin,
                                  purpose: string;
                                  remedy = ""): string =
  ## The diagnostic for a compiler that failed ``probeCCompiler``.
  ## ``remedy`` replaces the default ``cCompilerOverrideRemedy`` for a
  ## compile whose fallback differs: that text offers the pinned bootstrap
  ## compiler, which only the recipe compile provisions.
  var detail = probe.detail
  const maxDetail = 2000
  if detail.len > maxDetail:
    detail = detail[0 ..< maxDetail] & " [...]"
  result = "the C compiler selected for compiling the " & purpose & " cannot " &
    "compile a trivial C file that includes <stddef.h>" &
    (when defined(macosx): " and <Security/SecRandom.h>"
     else: "") &
    "\n  compiler: " & probe.compiler &
    "\n  selected from: " & origin &
    (when defined(macosx): "\n  SDKROOT: " &
      getEnv("SDKROOT", "<unset>") &
      "\n  " & bootstrapSdkRootEnv & ": " & getEnv(bootstrapSdkRootEnv, "<unset>")
     else: "") &
    "\n  failure: " & detail.replace("\n", "\n    ") &
    "\n  remedy: " & (if remedy.len > 0: remedy
                      else: cCompilerOverrideRemedy())

proc cCompilerUnusableMessage*(probe: CCompilerProbe; origin: string): string =
  ## Preserve the exact public two-argument proc type, not merely call syntax.
  cCompilerUnusableMessageFor(probe, origin, "recipe")
