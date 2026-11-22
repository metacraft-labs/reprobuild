## Test support (not a test): resolve Nimble requirements through the
## production path -- ``solverInput`` over an index built by the production
## writer, ``lowerToSolver``, the real clingo solve -- and read back what it
## chose.

import std/[sets, strutils, tables]

import repro_nimble_index
import repro_solver/[version_encoder, variant_encoder, solver_api]

import ./index_fixtures

export index_fixtures

type
  Resolved* = object
    input*: NimbleSolverInput
    chosen*: Table[string, string] ## identity -> version (Nimble and nim)
    failure*: string               ## "" when solved; else the message

const NoVariants*: seq[VariantDecl] = @[]

proc resolve*(packages: seq[PackageEnvelope];
              roots: seq[(string, string)];
              platform = LinuxAmd64;
              options = NimbleSolveOptions(excludeNewer: -1);
              nimVersions: seq[string] = @[];
              preference = vpNone): Resolved =
  ## Resolve ``roots`` (name, range) for a project package `app` against
  ## an index of ``packages``. With ``nimVersions``, the project also
  ## declares the `nim` toolchain package with those candidates (and the
  ## solve is one that declares `nim`, ``NimbleSolveOptions.nimDeclared``).
  let built = buildIndex(buildInput(packages))
  var idx = openIndex(memorySource(objectTable(built)), built.rootId)
  var names: seq[string]
  var opts = options
  if nimVersions.len > 0: opts.nimDeclared = true
  for (n, r) in roots:
    names.add n
    opts.roots.add RootRequirement(requirer: "app", name: n, range: r)
  result.input = solverInput(idx, names, platform, opts)
  var app = newPackage("app", ["0.1.0"])
  for (n, r) in roots:
    app.depends.add canonicalRequirement(result.input,
      newDependency("nimble:" & n, r))
  var decls = @[app]
  if nimVersions.len > 0:
    decls.add newPackage("nim", nimVersions)
    app.depends.add newDependency("nim", ">=0.0.0")
    decls[0] = app
  decls.add lowerToSolver(result.input,
    toolchainNim = (if nimVersions.len > 0: "nim" else: ""),
    nimVersions = nimVersions)
  try:
    let sol = solve(NoVariants, decls, preference)
    for k, v in sol.packages:
      if k.startsWith("nimble:") or k == "nim":
        result.chosen[k] = v
  except EUnsatisfiable as e:
    result.failure = e.msg & "\n" & explainNimbleFailure(result.input,
      "the fixture index")

proc tagged*(package, tag: string; requires: seq[RequirementEntry] = @[];
             nim = ""; firstSeen = 1_790_000_000'u64): VersionRecord =
  result = record(package, tag, requires, nim)
  result.firstSeen = firstSeen

proc pseudo*(package: string; kind: RecordVersionKind; tag, commit: string;
             requires: seq[RequirementEntry] = @[]): VersionRecord =
  result = record(package, "0.0.0", requires)
  result.version = RecordVersion(kind: kind, tag: tag)
  result.commit = commit

proc headReq*(name: string): RequirementEntry =
  RequirementEntry(targetKind: rtPackage, target: name, versionKind: rvHead,
    source: name & "#head")

proc commitReq*(name, commit: string): RequirementEntry =
  RequirementEntry(targetKind: rtPackage, target: name,
    versionKind: rvCommit, constraint: commit, source: name & "#" & commit)

proc urlReq*(url: string; constraint = ""): RequirementEntry =
  RequirementEntry(targetKind: rtUrl, target: url,
    versionKind: (if constraint.len > 0: rvRange else: rvAny),
    constraint: constraint, source: url & " " & constraint)
