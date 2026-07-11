import std/[strutils, tables]

import repro_dsl_stdlib/configurables
import repro_project_dsl

import "./repro" as fixture

if not hasSolverSolution():
  quit "no solver solution"

let sol = lastSolverSolution()
let resolved = sol.variants.getOrDefault("buildType", "")
if resolved != "release":
  quit "buildType resolved to '" & resolved & "' but expected 'release'"

resetBuildActionRegistry()
fixture.buildBuildtypeOutputPackage()
let edges = registeredBuildActions()
var sawRelease = false
for e in edges:
  for o in e.outputs:
    if "build/debug/" in o:
      quit "output still under build/debug with buildType=release: " & o
    if "build/release/" in o:
      sawRelease = true

if not sawRelease:
  quit "expected an output under build/release/ but found none"
