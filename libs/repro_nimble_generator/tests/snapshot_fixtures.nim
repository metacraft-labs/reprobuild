## Test support (not a test): resolving Nimble requirements against an index
## the generator built, through the production path -- ``solverInput``,
## ``canonicalRequirement``, ``lowerToSolver`` and the real clingo solve --
## for the NPC-M10 snapshot tests.

import std/[strutils, tables, times]

import repro_domain_types/nimble_index
import repro_nimble_index
import repro_nimble_reader/requirements
import repro_solver/[version_encoder, variant_encoder, solver_api]

type
  Solved* = object
    input*: NimbleSolverInput
    chosen*: Table[string, string] ## identity -> version
    failure*: string               ## "" when solved; else the message

const LinuxAmd64Platform* = NimblePlatform(id: "linux-amd64",
  targetOs: "linux", targetCpu: "amd64", hostOs: "linux", hostCpu: "amd64")

proc rootOf*(requirement: string): tuple[name, range: string] =
  ## A Nimble requirement string (`untagged ^= 0.1`) as the project's root:
  ## its name and its range normalized into the solver's language, as the
  ## static reader normalizes a `requires`.
  let r = readRequirements(requirement)
  doAssert r.errors.len == 0 and r.requirements.len == 1,
    "cannot read " & requirement
  let q = r.requirements[0]
  case q.version.kind
  of vkAny: (q.target.name, "")
  of vkRange: (q.target.name, q.version.normalized)
  else: (q.target.name, "")

proc solveOver*(objects: Table[IndexObjectId, seq[byte]]; rootId: IndexObjectId;
                requirements: seq[string]): Solved =
  ## Solve a project `app` requiring ``requirements`` (Nimble requirement
  ## strings) against the index ``rootId`` names.
  var idx = openIndex(memorySource(objects), rootId)
  var names: seq[string]
  var opts = NimbleSolveOptions(excludeNewer: -1)
  var roots: seq[(string, string)]
  for text in requirements:
    let (n, r) = rootOf(text)
    names.add n
    roots.add (n, r)
    opts.roots.add RootRequirement(requirer: "app", name: n, range: r)
  result.input = solverInput(idx, names, LinuxAmd64Platform, opts)
  var app = newPackage("app", ["0.1.0"])
  for (n, r) in roots:
    app.depends.add canonicalRequirement(result.input,
      newDependency("nimble:" & n, r))
  var decls = @[app]
  decls.add lowerToSolver(result.input)
  try:
    let sol = solve(newSeq[VariantDecl](), decls, vpNone)
    for k, v in sol.packages:
      if k.startsWith("nimble:"): result.chosen[k] = v
  except EUnsatisfiable as e:
    result.failure = e.msg & "\n" & explainNimbleFailure(result.input,
      "the generated index")

proc utcDateText*(t: uint64): string =
  ## The UTC date of ``t`` as eight digits, computed with `std/times`: an
  ## independent check of the codec's date.
  fromUnix(int64(t)).utc.format("yyyyMMdd")

proc candidateOf*(s: Solved; package, version: string): NimbleCandidate =
  let pi = s.input.packageOf(package)
  doAssert pi >= 0, package & " is not in the closure"
  for c in s.input.packages[pi].candidates:
    if c.version == version: return c
  doAssert false, package & " has no candidate " & version
