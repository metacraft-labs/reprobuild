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
## there would drag `sqlite3_binding` and `repro_shm_index` — and through
## the latter the external `shm_queue` sibling — into the profile
## compile's `--path` closure, which is not available to a profile.
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

proc realizationDirName*(version: string; prefixId: PrefixIdBytes): string =
  ## Directory name `<version>-<hash-prefix>`. We use the first 16 hex
  ## chars (64 bits) of the realization hash — enough to be collision
  ## resistant in a personal store while remaining human readable.
  let cleanVersion = safePathSegment(version, "v0")
  cleanVersion & "-" & hexOf(prefixId)[0 ..< 16]

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
  let pkgSegment =
    if outputName.len == 0 or outputName == "out":
      safePathSegment(packageName, "pkg")
    else:
      safePathSegment(packageName, "pkg") & "-" &
        safePathSegment(outputName, "out")
  "prefixes/" & pkgSegment & "/" & realizationDirName(version, prefixId)

proc casBlobRelative*(digest: PrefixIdBytes): string =
  let hex = hexOf(digest)
  "cas/blake3/" & hex[0 ..< 2] & "/" & hex
