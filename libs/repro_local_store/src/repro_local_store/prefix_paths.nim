## Pure prefix/CAS path arithmetic for the content-addressed local store.
##
## These helpers are the *naming* half of the store: given a package
## identity and a realization hash they compute the canonical relative
## path under `<store-root>/`. They touch no filesystem, no SQLite, and
## no shared memory — only `std/strutils`.
##
## They live in their own module (rather than inside `store.nim`) because
## non-store callers need the naming contract without the store runtime.
## In particular `repro_project_dsl/install_mirror_resolver` computes
## install-mirror paths while emitting build actions, and that module is
## in the import closure of every *profile* compile
## (`repro_profile_compile`). Importing all of `repro_local_store` from
## there would drag `sqlite3_binding` and the external `shm_gset` sibling
## (the action cache's Tier-2 index) into the profile compile's `--path`
## closure, which is not available to a profile.
##
## `store.nim` imports and re-exports this module, so every existing
## `repro_local_store` consumer keeps seeing the same symbols.

import std/strutils

type
  PrefixIdBytes* = array[32, byte]
    ## A BLAKE3-256 realization hash, the canonical primary key for the
    ## `prefixes` table.

proc safePathSegment*(value, fallback: string): string =
  ## Restricts an arbitrary string to a portable filesystem segment. We
  ## allow alphanumerics, `-`, `_`, `.` and pass everything else through
  ## an underscore. Empty input falls back to `fallback`.
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc hexOf*(bytes: openArray[byte]): string =
  ## Lower-case hex of the supplied byte sequence.
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc prefixIdHex*(p: PrefixIdBytes): string = hexOf(p)

const
  RealizationDirHexChars* = 40
    ## How many lowercase hex characters of the realization hash a prefix's
    ## directory name carries: 160 bits (Local-Content-Addressed-Store.md
    ## §"Realization Hash (normative)", "The directory name: the one
    ## truncation"). The hash is the prefix's whole identity; the name is a
    ## truncation of it, so two ids agreeing in these bits would name one
    ## directory. At 160 bits a chosen-input collision costs about 2^80
    ## hash evaluations.
  LegacyRealizationDirHexChars* = 16
    ## The width builds before the widening used: 64 bits, which anyone who
    ## can choose realization inputs can collide for about 2^32 work. Only
    ## READ: see ``legacyRealizationDirName``.

proc realizationDirName*(version: string; prefixId: PrefixIdBytes): string =
  ## Directory name ``<version>-<hash prefix>``: the first
  ## ``RealizationDirHexChars`` (40) lowercase hex characters, 160 bits, of
  ## the realization hash. Every new prefix is named this way.
  let cleanVersion = safePathSegment(version, "v0")
  cleanVersion & "-" & hexOf(prefixId)[0 ..< RealizationDirHexChars]

proc legacyRealizationDirName*(version: string;
                               prefixId: PrefixIdBytes): string =
  ## The name a build before the widening gave the prefix of ``prefixId``:
  ## ``<version>-<first 16 hex>`` (64 bits).
  ##
  ## READ-COMPATIBILITY ONLY. A store written by an older build holds
  ## prefixes under this name, recorded in their receipts and index rows,
  ## and units may bind them. Readers recognise such a prefix
  ## (``prefix_location.resolvePrefixRelativePath``, the store's recovery);
  ## nothing ever names a NEW prefix with it.
  let cleanVersion = safePathSegment(version, "v0")
  cleanVersion & "-" & hexOf(prefixId)[0 ..< LegacyRealizationDirHexChars]

proc prefixPackageSegment(packageName, outputName: string): string =
  ## ``<package>`` or, for a named non-``out`` output, ``<package>-<output>``.
  if outputName.len == 0 or outputName == "out":
    safePathSegment(packageName, "pkg")
  else:
    safePathSegment(packageName, "pkg") & "-" &
      safePathSegment(outputName, "out")

proc prefixRelativePath*(packageName, version: string;
                        prefixId: PrefixIdBytes;
                        outputName = ""): string =
  ## Returns the canonical relative path under `prefixes/` for the
  ## supplied identity. Always forward-slashed so the SQLite column is
  ## portable across hosts.
  ##
  ## Recipe-Val M8: ``outputName`` selects which Nix-style package
  ## output the prefix belongs to. An empty value (the default)
  ## preserves the legacy single-output layout
  ## ``prefixes/<package>/<version>-<hash>/``. A non-empty value
  ## inserts an output-name segment to give Nix-style
  ## ``prefixes/<package>-<output>/<version>-<hash>/`` partitioning
  ## — the package + output pair drives a fresh directory tree so
  ## each output's prefix is independently content-addressable and
  ## a downstream consumer can refer to one without dragging in the
  ## siblings.
  "prefixes/" & prefixPackageSegment(packageName, outputName) & "/" &
    realizationDirName(version, prefixId)

proc legacyPrefixRelativePath*(packageName, version: string;
                               prefixId: PrefixIdBytes;
                               outputName = ""): string =
  ## Where a build before the widening put this prefix:
  ## ``prefixRelativePath`` with ``legacyRealizationDirName``. Read-
  ## compatibility only, like that name; never used to place a new prefix.
  "prefixes/" & prefixPackageSegment(packageName, outputName) & "/" &
    legacyRealizationDirName(version, prefixId)

proc casBlobRelative*(digest: PrefixIdBytes): string =
  let hex = hexOf(digest)
  "cas/blake3/" & hex[0 ..< 2] & "/" & hex
