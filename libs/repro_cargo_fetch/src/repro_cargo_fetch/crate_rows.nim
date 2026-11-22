## The registry crates a `Cargo.lock` pins: what the fetch edges fetch.
##
## Every fetch edge is derived from the lockfile alone, without running
## cargo: cargo cannot plan a build before each package's manifest is on
## disk, so the fetch has to come first, and its only input is what the lock
## pins. A crates.io package in `Cargo.lock` (lock format v3 and v4) carries
## its name, its version and `checksum`, which is "A SHA256 checksum of the
## `.crate` file" (Cargo Book, "Registry Index",
## https://doc.rust-lang.org/cargo/reference/registry-index.html). That
## checksum is the one thing a fetched archive is verified against.
##
## The lockfile is read by `repro_core/cargo_lock`, which refuses anything it
## does not understand exactly (an unknown lock version, a registry package
## without a checksum, an unknown key). This module then sorts the packages
## into:
##
## * **rows**: crates.io packages, each one fetch edge;
## * **unfetched**: packages a fetch edge does not serve -- a `git+` source
##   (no checksum to verify against), any other registry, or any other
##   source. They are reported, never dropped silently and never fetched:
##   whether a workspace with such a package can be built at all is the
##   caller's decision, not the fetch's.
##
## Workspace members (no `source`) are what the build produces and appear in
## neither list.
##
## A row's name and version become path components of the store prefix and
## of every mirror and origin URL, so both are checked against the shapes
## crates.io allows before anything is built from them. A lockfile is
## project content, not trusted input.

import std/[algorithm, strutils, tables]

import repro_core/cargo_lock

type
  CrateRowError* = object of CatchableError
    ## A lockfile row a fetch edge will not be built from.

  CrateRow* = object
    ## One locked crates.io crate version: one `cargo.fetch` edge.
    name*: string     ## as published (case kept)
    version*: string  ## the index's `vers`
    cksum*: string    ## SHA-256 of the `.crate`, 64 lower-case hex

  UnfetchedPackage* = object
    ## A locked package no fetch edge serves, and why.
    name*, version*, source*, reason*: string

  LockedCrates* = object
    rows*: seq[CrateRow]             ## sorted by (name, version), unique
    unfetched*: seq[UnfetchedPackage]

const
  MaxCrateNameLen* = 64
    ## crates.io's limit on a crate name (Cargo Book, "The Manifest Format",
    ## "The `name` field": "max 64 characters of length").
  MaxVersionLen* = 256

proc label*(r: CrateRow): string = r.name & "@" & r.version

proc isCksum*(s: string): bool =
  s.len == 64 and s.allCharsInSet({'0'..'9', 'a'..'f'})

proc validateRow*(r: CrateRow) =
  ## Raise `CrateRowError` unless ``r`` has a crates.io name, a version that
  ## begins with a digit and holds only SemVer characters, and a SHA-256
  ## checksum. A name on crates.io is ASCII alphanumerics, `-` and `_`,
  ## starting with a letter (Cargo Book, "The `name` field"); a version is
  ## SemVer (https://semver.org), so `..`, `/` and every other character
  ## that could change the meaning of a path or a URL is refused.
  if r.name.len == 0 or r.name.len > MaxCrateNameLen or
      r.name[0] notin {'A'..'Z', 'a'..'z'} or
      not r.name.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}):
    raise newException(CrateRowError, "Cargo.lock: package name " &
      r.name.escape() & " is not a crates.io crate name")
  if r.version.len == 0 or r.version.len > MaxVersionLen or
      r.version[0] notin {'0'..'9'} or
      not r.version.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '.', '-',
        '+'}):
    raise newException(CrateRowError, "Cargo.lock: package " &
      r.name.escape() & " has version " & r.version.escape() &
      ", which is not a SemVer version")
  if not isCksum(r.cksum):
    raise newException(CrateRowError, "Cargo.lock: package " & r.label &
      " has checksum " & r.cksum.escape() & ", which is not 64 lower-case " &
      "hex digits (a SHA-256)")

proc lockedCrates*(packages: openArray[CargoLockPackage]): LockedCrates =
  ## Sort ``packages`` into fetch rows and unfetched packages (see the
  ## module docstring). Raises `CrateRowError` for a crates.io row with a
  ## bad shape, or for one name and version locked twice with two checksums.
  var seen = initTable[string, string]()   # label -> cksum
  for p in packages:
    if p.source.len == 0:
      continue
    if isRegistrySource(p.source):
      let row = CrateRow(name: p.name, version: p.version, cksum: p.checksum)
      validateRow(row)
      let key = row.label
      if key in seen:
        if seen[key] != row.cksum:
          raise newException(CrateRowError, "Cargo.lock: " & key &
            " is locked twice, with checksums " & seen[key] & " and " &
            row.cksum)
        continue
      seen[key] = row.cksum
      result.rows.add row
    elif p.source.startsWith("git+"):
      result.unfetched.add UnfetchedPackage(name: p.name, version: p.version,
        source: p.source, reason: "a git source has no checksum in " &
        "Cargo.lock to verify a download against")
    else:
      result.unfetched.add UnfetchedPackage(name: p.name, version: p.version,
        source: p.source, reason: "not a crates.io source")
  result.rows.sort(proc(a, b: CrateRow): int =
    result = cmp(a.name, b.name)
    if result == 0: result = cmp(a.version, b.version))

proc lockedCratesOf*(lockText: string): LockedCrates =
  ## `lockedCrates` over a `Cargo.lock`'s text. Raises `CargoLockError` for
  ## a lockfile `repro_core/cargo_lock` will not read, `CrateRowError` for a
  ## row a fetch edge will not be built from.
  lockedCrates(parseCargoLock(lockText))
