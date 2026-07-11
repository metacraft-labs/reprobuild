import std/[strutils, tables]

import repro_dsl_stdlib/configurables
import repro_project_dsl

import "./repro" as fixture

if not hasSolverSolution():
  quit "no solver solution"

let sol = lastSolverSolution()
let resolved = sol.variants.getOrDefault("enableTLS", "")
if resolved != "false":
  quit "enableTLS resolved to '" & resolved & "' but expected 'false'"

resetBuildActionRegistry()
fixture.buildVariantFeatureFlagPackage()
let edges = registeredBuildActions()
var tlsCount = 0
for e in edges:
  if "t_tls" in e.id:
    inc tlsCount
  for o in e.outputs:
    if "t_tls" in o:
      inc tlsCount
      break

if tlsCount != 0:
  quit "expected 0 TLS edges with enableTLS=false but got " & $tlsCount
if edges.len < 1:
  quit "expected at least one build edge but got 0"
