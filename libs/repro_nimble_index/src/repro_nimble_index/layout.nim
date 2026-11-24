## A record's layout and binary fields as they hold on one platform
## (NPC-AREQ5): the plain fields -- what the `.nimble` sets outside any
## `when` -- then every conditional entry (`layout.conditional`) whose
## condition holds there, in record order. An entry that assigns replaces
## the field and one that appends (`&=`, `add`) extends it, so the last
## assignment wins, as it does in the file.
##
## Every consumer of `srcDir`, `paths`, `binDir`, `backend`, the install
## rules (`installDirs`, `installFiles`, `installExt`, `skipDirs`,
## `skipFiles`, `skipExt`), `bin` or `namedBin` reads them through
## ``effectiveLayout``, never from the plain fields: a field set under
## `when defined(windows)` is otherwise silently the plain value on Windows.
##
## An entry whose condition depends on the Nim version is decided at the
## Nim given (the one the lock was solved for). Without one it is not
## applied, and the field is listed in ``undecided`` with its condition, so
## the caller refuses rather than guess.

import std/options

import repro_domain_types/nimble_index

import ./solver_input

type
  EffectiveLayout* = object
    layout*: RecordLayout
      ## the layout fields on the platform; ``conditional`` is empty and
      ## ``modules`` is the record's (computed under the plain `srcDir`)
    binaries*: RecordBinaries ## the binary fields on the platform
    undecided*: seq[tuple[field: RecordField; condition: string]]
      ## entries whose condition depends on the Nim version and no Nim was
      ## given, in record order: their fields are left as the earlier
      ## entries set them

proc applyEntry(e: var EffectiveLayout; c: RecordConditionalField) =
  template scalar(target: untyped) =
    if c.values.len > 0:
      if c.append: target.add c.values[^1]
      else: target = c.values[^1]
  template list(target: untyped) =
    if c.append: target.add c.values
    else: target = c.values
  case c.field
  of rfVersion: discard
  of rfSrcDir: scalar(e.layout.srcDir)
  of rfBinDir: scalar(e.binaries.binDir)
  of rfBackend: scalar(e.binaries.backend)
  of rfBin: list(e.binaries.bin)
  of rfNamedBin:
    if c.append: e.binaries.namedBin.add c.pairs
    else: e.binaries.namedBin = c.pairs
  of rfInstallDirs: list(e.layout.installDirs)
  of rfInstallFiles: list(e.layout.installFiles)
  of rfInstallExt: list(e.layout.installExt)
  of rfSkipDirs: list(e.layout.skipDirs)
  of rfSkipFiles: list(e.layout.skipFiles)
  of rfSkipExt: list(e.layout.skipExt)
  of rfPaths: list(e.layout.paths)

proc effectiveLayout*(rec: VersionRecord; p: NimblePlatform;
                      nim = none(NimVersionValue)): EffectiveLayout =
  ## See the module header.
  result.layout = rec.layout
  result.layout.conditional = @[]
  result.binaries = rec.binaries
  for c in rec.layout.conditional:
    if c.field == rfVersion: continue
    case decideOn(c.condition, p, nim)
    of tTrue: result.applyEntry(c)
    of tFalse: discard
    of tUnknown:
      result.undecided.add (c.field, renderCondition(c.condition))

proc undecidedText*(e: EffectiveLayout; fields: set[RecordField]): string =
  ## The condition of the first undecided entry of one of ``fields``; ""
  ## when none.
  for u in e.undecided:
    if u.field in fields: return u.condition
  ""
