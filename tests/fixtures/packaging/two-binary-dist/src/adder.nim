## Sample project binary #2 for the M0 packaging gate.
##
## The gate says "a trivial TWO-binary sample project" — two because a
## one-binary distribution cannot catch a staging bug that reuses one
## component's paths or action ids for another, which is the most likely
## way an install-tree builder goes wrong.
import std/[os, strutils]

when isMainModule:
  var total = 0
  for arg in commandLineParams():
    total += parseInt(arg)
  echo total
