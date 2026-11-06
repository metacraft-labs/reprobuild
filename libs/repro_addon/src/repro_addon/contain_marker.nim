## The marker an operator's containment leaves (spec §13 decision 51): a
## module of its own, with no imports of the add-on, so that every place
## an apply can happen -- the switch itself, the add-on's apply unit, the
## full engine's deploy agent -- can refuse while it exists (A11 review
## finding 6).

import std/os

proc containedMarkerPath*(stateDir = "/var/lib/repro/system"): string =
  stateDir / "addon" / "contained"

proc isContained*(stateDir = "/var/lib/repro/system"): bool =
  fileExists(containedMarkerPath(stateDir))
