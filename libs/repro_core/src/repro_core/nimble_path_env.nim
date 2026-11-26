## How a build hands its provider the source roots of the Nimble catalog
## packages its lock pins (Nim-Package-Path-Handling.md § 5), so the
## provider's `repro.paths` edge lists them without reading the lock, the
## index or the store itself.
##
## The CLI resolves the roots before the provider runs (each is
## `<store tree>/<srcDir>` of a locked package, in the lock's topological
## order, then name) and sets ``NimblePathDirsEnvVar``; the provider reads
## it. One root per line: a root is an absolute directory, and no directory
## name the store creates holds a newline.

import std/strutils

const NimblePathDirsEnvVar* = "REPRO_NIMBLE_PATH_DIRS"

proc encodeNimblePathDirs*(dirs: openArray[string]): string =
  ## The variable's value for ``dirs``, in their order.
  for i, d in dirs:
    if i > 0: result.add '\n'
    result.add d

proc decodeNimblePathDirs*(value: string): seq[string] =
  ## The roots ``value`` names, in order; empty lines are skipped.
  for line in value.split('\n'):
    if line.len > 0: result.add line

const NimDevelopSiblingsEnvVar* = "REPRO_NIM_DEVELOP_SIBLINGS"
  ## The develop overrides of the build's project and workspace that are
  ## not Nimble catalog packages: each a package name and the absolute
  ## checkout it is developed in. The provider puts such a sibling's source
  ## directory on `repro.paths` for a package its owner uses, read from the
  ## sibling's `.nimble` (Nimble-Package-Catalog NPC-AREQ27). A `nimble:`
  ## override is applied by the CLI itself, in ``NimblePathDirsEnvVar``.

proc encodeNimDevelopSiblings*(siblings: openArray[(string, string)];
                               notes: openArray[string] = []): string =
  ## One `<package>\t<directory>[\t<note>]` line per sibling, in the given
  ## order. ``notes[i]``, when given and not empty, is what `repro.paths`
  ## says of the sibling's line: `<dir> (declared repo <repo>)` or `<dir>
  ## (recorded override)` (Nim-Package-Path-Handling.md § 5).
  for i, (name, dir) in siblings:
    if i > 0: result.add '\n'
    result.add name & '\t' & dir
    if i < notes.len and notes[i].len > 0:
      result.add '\t' & notes[i].replace('\t', ' ').replace('\n', ' ')

proc decodeNimDevelopSiblingNotes*(value: string):
    seq[tuple[name, dir, note: string]] =
  ## The siblings ``value`` names, each with its note ("" when none); a
  ## line without a tab is skipped.
  for line in value.split('\n'):
    let parts = line.split('\t')
    if parts.len >= 2 and parts[0].len > 0 and parts[1].len > 0:
      result.add (parts[0], parts[1],
        if parts.len >= 3: parts[2 .. ^1].join(" ") else: "")

proc decodeNimDevelopSiblings*(value: string): seq[(string, string)] =
  ## The siblings ``value`` names; a line without a tab is skipped.
  for s in decodeNimDevelopSiblingNotes(value):
    result.add (s.name, s.dir)

const NimDevelopLockedEnvVar* = "REPRO_NIM_DEVELOP_LOCKED"
  ## Set to `1` by a `--locked` build (Workspace-And-Develop-Mode.md §"A
  ## locked build sets aside every develop override"): the provider puts no
  ## working tree of a workspace sibling on `repro.paths` -- neither a
  ## recorded override's nor one matched by directory name. The compile
  ## receives a locked dependency's tree through the producer channel.
