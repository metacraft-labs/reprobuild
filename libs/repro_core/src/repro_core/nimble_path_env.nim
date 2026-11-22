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
