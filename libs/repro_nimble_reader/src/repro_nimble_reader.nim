## `repro_nimble_reader` — read a Nimble package's `.nimble` file as data.
##
## The Nimble package catalog stores, for every version of every registry
## package, the requirements and layout its `.nimble` file declares, so that
## resolution never reads a `.nimble`, runs NimScript or runs Nimble
## (NPC-AREQ8). This library is the one place a `.nimble` is read: by the
## catalog generator at each tag, and by develop mode for a workspace
## sibling's working tree (NPC-AREQ27), with the same code.
##
## * `requirements` — Nimble requirement strings, translated into the
##   solver's constraint language (NPC-AREQ6) and the `nimble:` namespace.
## * `conditions` — `when` conditions over the closed term set (NPC-AREQ7).
## * `reader` — the static reader of the declarative subset and its classes.
## * `lexer`, `syntax` — the purely syntactic Nim reader underneath.
##
## Reading never evaluates anything: no NimScript VM, no `nimble`, no process,
## no file but the `.nimble` itself (threat model G1).

{.push raises: [].}

import std/[algorithm, os, strutils]

import repro_nimble_reader/reader

export reader

type
  LookupKind* = enum
    lkFound    ## exactly one `.nimble` file
    lkNone     ## no `.nimble` file in the directory
    lkMultiple ## more than one; Nimble refuses such a package
    lkError    ## the directory could not be listed

  NimbleLookup* = object
    case kind*: LookupKind
    of lkFound:
      path*: string
    of lkMultiple:
      candidates*: seq[string]
    of lkNone:
      discard
    of lkError:
      message*: string

  PackageReadingKind* = enum
    prRead ## the `.nimble` was read (see its class)
    prNoNimbleFile
    prAmbiguous
    prIoError

  PackageReading* = object
    ## A package directory read for develop mode or the generator.
    case kind*: PackageReadingKind
    of prRead:
      nimbleFile*: string
      file*: NimbleFile
    of prAmbiguous:
      candidates*: seq[string]
    of prNoNimbleFile:
      discard
    of prIoError:
      message*: string

proc findNimbleFile*(packageDir: string): NimbleLookup =
  ## The package's `.nimble` file: the one regular file directly in
  ## `packageDir` named `*.nimble` (or the legacy `*.babel`), as Nimble finds
  ## it.
  var found: seq[string]
  try:
    for kind, path in walkDir(packageDir, checkDir = true):
      if kind in {pcFile, pcLinkToFile}:
        let ext = splitFile(path).ext
        if ext == ".nimble" or ext == ".babel":
          found.add path
  except OSError as e:
    return NimbleLookup(kind: lkError, message: e.msg)
  sort(found)
  case found.len
  of 0: NimbleLookup(kind: lkNone)
  of 1: NimbleLookup(kind: lkFound, path: found[0])
  else: NimbleLookup(kind: lkMultiple, candidates: found)

proc readNimbleFile*(path: string; error: var string;
                     options = ReaderOptions()): NimbleFile =
  ## Read one `.nimble` file from disk. On an I/O error `error` is set and the
  ## returned record is empty.
  error = ""
  var src = ""
  try:
    src = readFile(path)
  except IOError as e:
    error = e.msg
    return NimbleFile(fileName: extractFilename(path))
  readNimbleSource(src, extractFilename(path), options)

proc readPackageDir*(packageDir: string;
                     options = ReaderOptions()): PackageReading =
  ## Find and read the `.nimble` of a package directory — a workspace
  ## sibling's working tree in develop mode, or a checked-out tag in the
  ## generator.
  let lookup = findNimbleFile(packageDir)
  case lookup.kind
  of lkNone:
    PackageReading(kind: prNoNimbleFile)
  of lkMultiple:
    PackageReading(kind: prAmbiguous, candidates: lookup.candidates)
  of lkError:
    PackageReading(kind: prIoError, message: lookup.message)
  of lkFound:
    var err = ""
    let f = readNimbleFile(lookup.path, err, options)
    if err.len > 0:
      PackageReading(kind: prIoError, message: err)
    else:
      PackageReading(kind: prRead, nimbleFile: lookup.path, file: f)

proc sourceDir*(f: NimbleFile; packageDir: string): string =
  ## The directory that goes on the compiler's `--path` for this package: the
  ## package directory joined with its `srcDir` (Nimble's `realDir`).
  if f.srcDir.len == 0:
    return packageDir
  packageDir / f.srcDir.strip(leading = false, chars = {'/', '\\'})
