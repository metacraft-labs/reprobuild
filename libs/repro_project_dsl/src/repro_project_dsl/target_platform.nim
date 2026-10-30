## The platform a build for a target triple is PUBLISHED under.
##
## ReproOS-Add-On-Mode A15, fourth deliverable. A binary-cache entry is keyed
## by the platform of the host whose apply or build looks it up, and that
## host derives its own key from what it is (`compat_check.detectLocalPlatform`):
## on every Linux host `abi = "gnu"` and `libcVariant = ""`, whatever the
## binary it will run was linked against. So a static-musl `llm-api-proxy`
## built for `armv7-unknown-linux-musleabihf` and substituted by a glibc
## Raspberry Pi OS host is published under `armv7 / linux / gnu / ""` -- the
## Pi's platform -- and the triple contributes its CPU family and OS only.
## This module is that mapping, in the layer every identity composer can
## reach (`source_cache_identity` below the stdlib, `cross_target_flag` in
## the CLI); `activeTargetTripleTag` beside it is the triple itself.

import std/strutils

import repro_binary_cache_server/types as bc_types
import ./install_mirror_resolver

export activeTargetTripleTag

proc targetTripleCpu*(triple: string): string =
  ## The cache's CPU family of a triple's first component: `armv7`,
  ## `aarch64`, `x86_64`, `i686`, `riscv64`. `arm`, `armv7l`, `armhf` spell
  ## the `armv7` family (every supported 32-bit ARM target is ARMv7
  ## hard-float). Raises for a family the cache does not key by, because an
  ## entry published under it could never be substituted.
  let head = triple.split('-')[0].toLowerAscii()
  case head
  of "x86_64", "amd64", "x64": "x86_64"
  of "aarch64", "arm64": "aarch64"
  of "arm", "armv7", "armv7l", "armv7h", "armhf", "armv7a": "armv7"
  of "i386", "i586", "i686", "x86": "i686"
  of "riscv64": "riscv64"
  else:
    raise newException(ValueError,
      "target '" & triple & "': '" & head & "' names no CPU family the " &
      "binary cache keys by (x86_64, aarch64, armv7, i686, riscv64)")

proc targetTripleOs*(triple: string): string =
  ## The OS component (`linux`, `darwin`, `windows`), wherever the triple
  ## puts it.
  for part in triple.toLowerAscii().split('-'):
    case part
    of "linux": return "linux"
    of "darwin", "macos", "macosx": return "darwin"
    of "windows", "win32", "mingw32": return "windows"
    else: discard
  raise newException(ValueError,
    "target '" & triple & "' names no OS (linux, darwin, windows)")

proc consumerPlatformForTarget*(triple: string): PlatformTriple =
  ## The platform a build for `triple` is published under (see the header):
  ## CPU and OS from the triple; ABI and libc what `detectLocalPlatform`
  ## reports on a host of that OS.
  let os = targetTripleOs(triple)
  result.cpu = targetTripleCpu(triple)
  result.os = os
  case os
  of "linux": result.abi = "gnu"
  of "windows": result.abi = "msvc"
  else: result.abi = ""
  result.libcVariant = ""
