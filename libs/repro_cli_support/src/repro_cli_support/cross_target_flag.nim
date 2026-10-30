## `repro build --target=<triple>`: the spelling of a cross target on the
## command line, and the platform a build for it is published under.
##
## ReproOS-Add-On-Mode A15 / Reprobuild-Standard-Library §"Worked Example:
## Cross-Compilation". `--target` is sugar for `--variant
## targetTriple=<triple>`: the flag writes the same `REPRO_VARIANTS`
## assignment the `--variant` flag writes, the stdlib's one variant read site
## (`toolchain_policy.activeSolvedVariants`) picks it up, and the active
## build context fills its `crossTarget` slot with the adapter that claims
## the triple. Nothing else in the engine is target-specific; every typed-tool
## call that reads the slot is.
##
## ## Two spellings
##
## * A full triple (`armv7-unknown-linux-musleabihf`, `aarch64-linux-gnu`)
##   is taken as written, lower-cased. Which adapter serves it is the
##   stdlib's decision at emission; an unclaimed triple reaches the generic
##   `crossTargetFromTriple` stub and a recipe that needs more refuses it by
##   name there.
## * The short `<cpu>-<os>` form (`armv7-linux`) names the catalog's
##   CANONICAL appliance target for that family: the static-musl triple the
##   zig adapter builds, which is the one a host without a matching sysroot
##   can run (`ZigCrossTargets`). It is the spelling the Add-On Mode
##   milestone uses for the Raspberry Pi 2.
##
## ## The published platform is the CONSUMER's, not the binary's
##
## A build-action cache entry is keyed by the platform of the host whose
## apply looks it up (`binary_cache_build_actions.buildActionCacheIdentity`;
## Binary-Caches.md §"Publishing for a host that cannot build"), and that
## host derives its own key from `detectLocalPlatform`: on every Linux host
## `abi = "gnu"` and `libcVariant = ""`, whatever the binary it will run was
## linked against. A static-musl `llm-api-proxy` is substituted by a glibc
## Raspberry Pi OS host, so the key it is published under says `armv7 /
## linux / gnu / ""` -- the Pi's platform -- and NOT `musl`. The triple
## therefore contributes only its CPU family and OS to the key; the ABI and
## libc fields are the consumer's conventions, and `--platform-abi` /
## `--platform-libc` on the publish override them for a consumer whose
## conventions differ.

import std/[sequtils, strutils]

import repro_binary_cache_server/types as bc_types
import repro_dsl_stdlib/packages_schema

const
  TargetTripleVariantName* = "targetTriple"

  ShortTargetAliases* = [
    ("armv7-linux", "armv7-unknown-linux-musleabihf"),
    ("aarch64-linux", "aarch64-unknown-linux-musl"),
    ("x86_64-linux", "x86_64-unknown-linux-musl"),
  ]
    ## `<cpu>-<os>` -> the canonical appliance triple (see the header).
    ## Every right-hand side is a row of `cross_zig.ZigCrossTargets`; the
    ## stdlib test `t_cross_target_flag` checks that so the two tables
    ## cannot drift.

proc canonicalTargetTriple*(spelling: string): string =
  ## The `targetTriple` value `--target=<spelling>` assigns, or "" for
  ## `native` (a build for the host, which is also the default). Raises
  ## `ValueError` for a spelling that is neither a known short form nor
  ## shaped like a triple.
  let s = spelling.strip().toLowerAscii()
  if s.len == 0:
    raise newException(ValueError,
      "--target expects a triple (armv7-unknown-linux-musleabihf) or a " &
      "short form (armv7-linux); got an empty value")
  if s == "native":
    return ""
  for (short, full) in ShortTargetAliases:
    if s == short:
      return full
  let parts = s.split('-')
  if parts.len < 2 or parts.len > 4 or parts.anyIt(it.len == 0):
    raise newException(ValueError,
      "--target '" & spelling & "' is not a target triple " &
      "(<cpu>-<vendor>-<os>-<abi>, <cpu>-<os>-<abi>) nor a short form (" &
      ShortTargetAliases.mapIt(it[0]).join(", ") & ")")
  if parts.len == 2:
    raise newException(ValueError,
      "--target '" & spelling & "' names no canonical target; the short " &
      "forms are " & ShortTargetAliases.mapIt(it[0]).join(", ") &
      " -- spell any other target as a full triple")
  s

proc targetTripleCpu*(triple: string): string =
  ## The cache's CPU family of a triple's first component: `armv7`,
  ## `aarch64`, `x86_64`, `i686`, `riscv64`. `arm` and `armv7l` spell the
  ## `armv7` family (every supported 32-bit ARM target is ARMv7 hard-float,
  ## `compat_check.detectLocalPlatform`). Raises for a family the cache
  ## does not key by, because an entry published under it could never be
  ## substituted (`infra.canonicalPlatformCpu` refuses the same way).
  let head = triple.split('-')[0]
  case head
  of "arm", "armv7", "armv7l", "armv7h", "armhf", "armv7a": return "armv7"
  of "i386", "i586", "i686": return "i686"
  else: discard
  let parsed = parsePlatformCpuToken(head)
  if not parsed.ok or parsed.cpu == pcAny:
    raise newException(ValueError,
      "--target '" & triple & "': '" & head & "' names no CPU family the " &
      "binary cache keys by (x86_64, aarch64, armv7, i686, riscv64)")
  $parsed.cpu

proc targetTripleOs*(triple: string): string =
  ## The OS component (`linux`, `darwin`, `windows`), wherever the triple
  ## puts it. `macos` / `apple-darwin` spell `darwin`.
  for part in triple.split('-'):
    case part
    of "linux": return "linux"
    of "darwin", "macos", "macosx": return "darwin"
    of "windows", "win32", "mingw32": return "windows"
    else: discard
  raise newException(ValueError,
    "--target '" & triple & "' names no OS (linux, darwin, windows)")

proc consumerPlatformForTarget*(triple: string): PlatformTriple =
  ## The platform a build for `triple` is published under: the platform the
  ## CONSUMING host derives (see the header). CPU and OS come from the
  ## triple; ABI and libc are what `detectLocalPlatform` reports on a host
  ## of that OS.
  let os = targetTripleOs(triple)
  result.cpu = targetTripleCpu(triple)
  result.os = os
  case os
  of "linux":
    result.abi = "gnu"
    result.libcVariant = ""
  of "windows":
    result.abi = "msvc"
    result.libcVariant = ""
  else:
    result.abi = ""
    result.libcVariant = ""
