## ReproOS-Campaign-Completion M6 deliverable 4: every catalog diagnostic a
## user can reach is actionable at the CLI.
##
## Each refusal below is triggered over the hermetic published-catalog
## fixture (``federated_catalog_fixture``: real catalog repositories whose
## artifacts their own providers generated, read through the shared clones)
## and asserted, EXACT TEXT, through the library entry points the ``repro``
## binary prints from:
##
##   * ``repro build`` -- ``buildProvisioningPins`` raises
##     ``ProvisioningSelectionRefused``; the dispatcher prints
##     ``reproBuildErrorText(msg)`` and exits 1. Inspection, ``repro
##     develop`` and dev-env activation resolve the same pins; activation
##     prints ``devEnvProvisioningRefusalText(msg)``, provisions nothing and
##     is never fatal;
##   * ``repro lock refresh --provisioning`` -- ``reselectCommittedProvisioning``;
##     the verb prints ``renderReselectionRefusal`` and exits 1, leaving the
##     lock byte-identical (both asserted);
##   * ``repro lock diff`` -- ``lockDiffReport`` (rc 1 changes, 2 refused).
##
## Every text names the catalog by its declared ``repo`` and ``remote``,
## the package and the candidates with their published source locations,
## the file to edit (``repro-catalogs.toml`` with the table's line, or the
## lock) and the exact command or edit. Host paths in these texts are the
## consumer's own files and shared clones; the tests also assert they reach
## neither the lock nor any composed digest.
##
## Built and run on Windows only in this round (WSL down).

import std/[algorithm, options, os, osproc, sequtils, strutils, tables, tempfiles,
            unittest]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/catalog_declaration
import repro_interface_artifacts/contribution_fingerprint
import repro_cli_support
import repro_lock
import repro_project_dsl

import ./federated_catalog_fixture

package federatedTool:
  executable federatedTool:
    name "federated-tool"
    cli:
      subcmd "run":
        flag verbose, bool

package federatedConsumer:
  defaultToolProvisioning "tarball"
  uses:
    "federatedTool"

let Host = currentPlatformId()

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc consumerDef(contributor: string; archive: FixtureArchive;
                 toolFingerprint: string): ProvisioningContributionDef =
  ProvisioningContributionDef(targetPackage: FedToolPackage,
    targetInterfaceFingerprint: toolFingerprint, contributor: contributor,
    tarballProvisioning: @[TarballProvisioningDef(url: archive.url,
      sha256: archive.sha256, archiveType: "tar.gz",
      executablePath: fixtureExecutableRelPath(FedToolExecutable),
      stripComponents: 1, packageId: FedToolPackageId,
      lockIdentity: "sha256:" & archive.sha256)],
    sourceFile: "catalogs/" & contributor.split('/')[^1] & "/repro.nim",
    sourceLine: 3)

proc consumerArtifact(defs: seq[ProvisioningContributionDef];
                      consumerRoot: string): ProjectInterfaceArtifact =
  var pi = toProjectInterface(findPackage("federatedConsumer"),
    registeredPackages(), defs)
  markImportedContributions(pi, consumerRoot / "repro.nim")
  artifactFor(pi)

proc baseLockText(): string =
  serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, platform: Host, optimal: true,
    inputsDigest: inputsDigestOf("federated-diagnostics"),
    packages: @[LockedPackage(name: "nim", version: "2.2.8", source: "nim",
      selection: ssSelected)]))

var consumersRoot = ""

proc consumer(name: string; imports: seq[ImportSpec];
              policy: seq[(string, string)] = @[(FedToolPackage,
                FedContributorA)]): string =
  result = consumersRoot / name
  createDir(result)
  writeFile(result / "repro.solver", "package app\nversions: 1.0.0\n")
  writeFile(result / "repro.lock", baseLockText())
  writeDeclaration(result, imports, policy)

proc refresh(dir: string): int =
  runReproLockCommand(@["refresh", dir, "--inputs", dir / "repro.solver",
    "--provisioning"])

proc refreshRefusal(dir: string): string =
  ## What ``repro lock refresh --provisioning <dir>`` prints when it refuses
  ## -- after checking the verb exits 1 and leaves the lock byte-identical.
  let lock = dir / "repro.lock"
  let before = readFile(lock)
  doAssert refresh(dir) == 1, "refresh unexpectedly succeeded for " & dir
  doAssert readFile(lock) == before, "a refused refresh wrote the lock"
  let outcome = reselectCommittedProvisioning(dir, lock, true, before, before,
    Host, Host)
  doAssert not outcome.reselected
  doAssert outcome.document == ""
  renderReselectionRefusal("refresh", lock, outcome.refusals)

proc buildRefusal(dir: string; defs: seq[ProvisioningContributionDef]):
    string =
  try:
    discard buildProvisioningPins(consumerArtifact(defs, dir), dir)
    ""
  except ProvisioningSelectionRefused as err:
    err.msg

proc fill(t: string; values: Table[string, string]): string =
  ## ``t`` with every ``{name}`` replaced by ``values[name]``; an unknown
  ## placeholder is a test bug.
  result = t
  for k, v in values:
    result = result.replace("{" & k & "}", v)
  doAssert "{" notin result or "{.error" in result,
    "unfilled placeholder in: " & result

proc same(actual, expected: string): bool =
  ## Exact equality, with the first difference printed when it fails.
  result = actual == expected
  if not result:
    var i = 0
    while i < min(actual.len, expected.len) and actual[i] == expected[i]:
      inc i
    echo "    --- actual (first difference at byte ", i, "):\n", actual,
      "\n    --- expected:\n", expected
    echo "    --- actual from there: ", actual[min(i, actual.len) ..
      ^1].escape()
    echo "    --- expected from there: ", expected[min(i, expected.len) ..
      ^1].escape()

proc templ(actual: string; t: Table[string, string]): string =
  ## ``actual`` with every known value replaced by its ``{name}``, longest
  ## value first -- how a golden text below was made from an observed one.
  var pairs: seq[(string, string)] = @[]
  for k, v in t:
    if v.len >= 6: pairs.add((k, v))
  pairs.sort(proc (a, b: (string, string)): int =
    result = cmp(b[1].len, a[1].len)
    if result == 0: result = cmp(a[0], b[0]))
  result = actual
  for (k, v) in pairs:
    result = result.replace(v, "{" & k & "}")

var golden = initTable[string, string]()
  ## name -> golden text; see ``expectText``.

proc expectText(name, actual: string; t: Table[string, string]): bool =
  ## ``actual`` must be EXACTLY the golden text ``name`` with its
  ## placeholders filled from ``t``. With no golden text yet, print the
  ## observed text as one (for review) and fail.
  if name notin golden:
    echo "=== GOLDEN ", name, "\n", templ(actual, t), "\n=== END ", name
    return false
  same(actual, fill(golden[name], t))

proc loadGolden() =
  ## The golden texts: each observed once, reviewed, and its run-specific
  ## values replaced by placeholders (``templ``).
  golden["ambiguous"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  unresolved-contribution-ambiguity: package "federatedTool" (interface {fp}) has 2 eligible provisioning contributions and no lock or curator policy selects one; import order is never a selection rule (Provisioning-Contributions.md, Resolution). Candidates: contributor "github:example/fed-catalog-a" from catalog fed-catalog-a|{remoteA}@{revA1}#{idA} declared at repro.nim:6; contributor "github:example/fed-catalog-b" from catalog fed-catalog-b|{remoteB}@{revB1}#{idB} declared at repro.nim:6. Pin one with an explicit selection.
      candidates:
        contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
        contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:13)
      fix: in {decl}, add a curator policy naming one of "github:example/fed-catalog-a", "github:example/fed-catalog-b":
          [[policy]]
          package = "federatedTool"
          contributor = "github:example/fed-catalog-a"
        then re-select with `repro lock refresh --provisioning {dir}`"""
  golden["same-contributor"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  unresolved-contribution-ambiguity: package "federatedTool" (interface {fp}) has 2 eligible provisioning contributions from contributor "github:example/fed-catalog-a", which the curator policy selects; a contributor id names one publisher, so the policy cannot choose between the catalogs that offer it, and import order is never a selection rule (Provisioning-Contributions.md, Resolution). Candidates: contributor "github:example/fed-catalog-a" from catalog fed-catalog-a-mirror|{remoteMA}@{revMA}#{idA} declared at repro.nim:6; contributor "github:example/fed-catalog-a" from catalog fed-catalog-a|{remoteA}@{revA1}#{idA} declared at repro.nim:6. Import only the catalog that should offer it.
      candidates:
        contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a-mirror" ({remoteMA}) at {revMA}, declared at repro.nim:6 (imported at {decl}:18)
        contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
      fix: contributor "github:example/fed-catalog-a" is offered by 2 imported catalogs: "fed-catalog-a-mirror" ({decl}:18), "fed-catalog-a" ({decl}:8). A contributor id names one publisher and no policy can choose between two catalogs that claim it: remove the [[import]] of the catalog that should not offer it from {decl} (or pin it at a revision that does not), then re-select with `repro lock refresh --provisioning {dir}`"""
  golden["duplicate-owner"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  duplicate-canonical-interface: package "federatedTool" has more than one canonical interface owner: catalog fed-packages-mirror|{remoteMP}@{revMP}#{idP} declares {fp}; catalog fed-packages|{remoteP}@{revP}#{idP} declares {fp}. Exactly one catalog may own a canonical package interface; split the declaration or drop one of the imports.
      owners:
        catalog "fed-packages-mirror" ({remoteMP}) at {revMP} declares interface {fp} at repro.nim:3 (imported at {decl}:18)
        catalog "fed-packages" ({remoteP}) at {revP} declares interface {fp} at repro.nim:3 (imported at {decl}:3)
      fix: exactly one imported catalog may own the canonical interface of "federatedTool": in {decl}, remove the [[import]] of every owner but one ("fed-packages" at {decl}:3, "fed-packages-mirror" at {decl}:18), then re-select with `repro lock refresh --provisioning {dir}`
  policy-selection-unsatisfied: curator policy selects contributor "github:example/fed-catalog-a" for package "federatedTool", but no imported catalog offers an eligible contribution from it. Eligible contributors: <none>.
      fix: no contribution for "federatedTool" is eligible until the duplicate-canonical-interface refusal is resolved; resolve that first (the [[policy]] for it ({decl}:23 names "github:example/fed-catalog-a") can stay)"""
  golden["incompatible"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  incompatible-interface-fingerprint: contribution from "github:example/fed-catalog-a" in catalog fed-catalog-a|{remoteA}@{revA1}#{idA} targets package "federatedTool" at interface fingerprint {fp}, but the composed canonical interface is {fp2} (contribution declared at repro.nim:6). The contribution is pinned to a superseded interface revision and must be refreshed against the current interface.
      contribution: contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8), pinned to interface {fp}
      canonical interface: catalog "fed-packages" ({remoteP}) at {revP2} declares interface {fp2} at repro.nim:3 (imported at {decl}:3)
      fix: in {decl}, pin catalog "fed-catalog-a" ({decl}:8) at a revision published against interface {fp2}, or pin catalog "fed-packages" ({decl}:3) at the revision whose interface the contribution names, or remove the [[import]] of "fed-catalog-a"; then re-select with `repro lock refresh --provisioning {dir}`. The publisher of "fed-catalog-a" fixes it by republishing with `interfaceFingerprint "{fp2}"` at repro.nim:6
  incompatible-interface-fingerprint: contribution from "github:example/fed-catalog-b" in catalog fed-catalog-b|{remoteB}@{revB1}#{idB} targets package "federatedTool" at interface fingerprint {fp}, but the composed canonical interface is {fp2} (contribution declared at repro.nim:6). The contribution is pinned to a superseded interface revision and must be refreshed against the current interface.
      contribution: contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:13), pinned to interface {fp}
      canonical interface: catalog "fed-packages" ({remoteP}) at {revP2} declares interface {fp2} at repro.nim:3 (imported at {decl}:3)
      fix: in {decl}, pin catalog "fed-catalog-b" ({decl}:13) at a revision published against interface {fp2}, or pin catalog "fed-packages" ({decl}:3) at the revision whose interface the contribution names, or remove the [[import]] of "fed-catalog-b"; then re-select with `repro lock refresh --provisioning {dir}`. The publisher of "fed-catalog-b" fixes it by republishing with `interfaceFingerprint "{fp2}"` at repro.nim:6
  policy-selection-unsatisfied: curator policy selects contributor "github:example/fed-catalog-a" for package "federatedTool", but no imported catalog offers an eligible contribution from it. Eligible contributors: <none>.
      fix: no contribution for "federatedTool" is eligible until the incompatible-interface-fingerprint refusal is resolved; resolve that first (the [[policy]] for it ({decl}:18 names "github:example/fed-catalog-a") can stay)"""
  golden["unknown-target"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  policy-selection-unsatisfied: curator policy selects contributor "github:example/fed-catalog-a" for package "federatedTool", but no imported catalog offers an eligible contribution from it. Eligible contributors: <none>.
      fix: no contribution for "federatedTool" is eligible until the unknown-target-interface refusal is resolved; resolve that first (the [[policy]] for it ({decl}:13 names "github:example/fed-catalog-a") can stay)
  unknown-target-interface: contribution from "github:example/fed-catalog-a" in catalog fed-catalog-a|{remoteA}@{revA1}#{idA} targets package "federatedTool" (declared at repro.nim:6), but no imported catalog declares a canonical interface for it. Import the catalog that owns the interface, or remove the contribution.
      contribution: contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:3)
      fix: in {decl}, add an [[import]] for the catalog that publishes the canonical interface of "federatedTool", or remove the [[import]] of "fed-catalog-a" ({decl}:3); then re-select with `repro lock refresh --provisioning {dir}`
  unknown-target-interface: contribution from "github:example/fed-catalog-b" in catalog fed-catalog-b|{remoteB}@{revB1}#{idB} targets package "federatedTool" (declared at repro.nim:6), but no imported catalog declares a canonical interface for it. Import the catalog that owns the interface, or remove the contribution.
      contribution: contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:8)
      fix: in {decl}, add an [[import]] for the catalog that publishes the canonical interface of "federatedTool", or remove the [[import]] of "fed-catalog-b" ({decl}:8); then re-select with `repro lock refresh --provisioning {dir}`"""
  golden["unsatisfied"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  policy-selection-unsatisfied: curator policy selects contributor "github:example/nobody" for package "federatedTool", but no imported catalog offers an eligible contribution from it. Eligible contributors: "github:example/fed-catalog-a", "github:example/fed-catalog-b".
      eligible: contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a-mirror" ({remoteMA}) at {revMA}, declared at repro.nim:6 (imported at {decl}:18)
      eligible: contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
      eligible: contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:13)
      fix: in {decl}, change the [[policy]] for package "federatedTool" ({decl}:23 names "github:example/nobody") to name one of the eligible contributors "github:example/fed-catalog-a", "github:example/fed-catalog-b", or add the [[import]] of the catalog that publishes "github:example/nobody"; then re-select with `repro lock refresh --provisioning {dir}`"""
  golden["contradictory"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  contradictory-curator-policy: curator policy names 2 different contributors for package "federatedTool": "github:example/fed-catalog-a", "github:example/fed-catalog-b". A policy entry's position is no more a selection rule than an import's (Provisioning-Contributions.md, Resolution): which of two contradictory entries wins is undecidable, so composition refuses rather than taking the one written last. Keep exactly one entry per package.
      fix: in {decl}, keep exactly one [[policy]] table for package "federatedTool" ({decl}:22 names "github:example/fed-catalog-a"; {decl}:18 names "github:example/fed-catalog-b") and delete the others, then re-select with `repro lock refresh --provisioning {dir}`"""
  golden["no-declaration"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: the project declares no catalog imports: {decl} does not exist. Declare the catalogs it imports there (Federated-Catalog-Imports.md); a catalog is never inferred from a sibling directory. Create it with `schema = "reprobuild.catalog-imports.v1"` and one [[import]] table (`repo`, `remote`, and `commit` or `ref`) per catalog"""
  golden["bad-declaration"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: the catalog import declaration cannot be read:
    {decl}:3: unknown key "branch" in [[import]] (accepted: repo, remote, commit, ref, interface_artifact)
    {decl}:9: unknown key "branch" in [[import]] (accepted: repo, remote, commit, ref, interface_artifact)
    fix: correct {decl} as stated above (Federated-Catalog-Imports.md, "Reading the file")"""
  golden["no-ref"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): there is no branch or tag "no-such-branch" in the shared clone {storeA} of {remoteA}; fetch it (`repro ws sync`) or pin a `commit`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["no-publication"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {revNothing}: the commit publishes no interface artifacts (there is no `published-interfaces/` directory at the repository root). A catalog publishes its generated artifacts there; its provider is never run to discover contributions. Pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["no-store"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): there is no shared clone of catalog remote {remoteA} at {storeA}. Populate it with `repro ws sync` (or `git clone --bare {remoteA} {storeA}`). Discovery reads ONLY that store -- never a working checkout, a sibling directory or a develop override
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["policy-contradicts-lock"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  policy-contradicts-lock: the committed lock pins contributor "github:example/fed-catalog-a" (contribution {cfA1}) for package "federatedTool", but the curator policy selects "github:example/fed-catalog-b". Neither is followed silently: refresh the lock to adopt the policy, or change the policy back.
    fix: to adopt the curator policy ({decl}:18 names "github:example/fed-catalog-b"), re-select with `repro lock refresh --provisioning {dir}`; to keep the locked selection, change that [[policy]] back to contributor "github:example/fed-catalog-a"
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["repro-build"] = """
repro build: error: provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  policy-contradicts-lock: the committed lock pins contributor "github:example/fed-catalog-a" (contribution {cfA1}) for package "federatedTool", but the curator policy selects "github:example/fed-catalog-b". Neither is followed silently: refresh the lock to adopt the policy, or change the policy back.
    fix: to adopt the curator policy ({decl}:18 names "github:example/fed-catalog-b"), re-select with `repro lock refresh --provisioning {dir}`; to keep the locked selection, change that [[policy]] back to contributor "github:example/fed-catalog-a"
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["dev-env"] = """
repro dev-env: error: provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  policy-contradicts-lock: the committed lock pins contributor "github:example/fed-catalog-a" (contribution {cfA1}) for package "federatedTool", but the curator policy selects "github:example/fed-catalog-b". Neither is followed silently: refresh the lock to adopt the policy, or change the policy back.
    fix: to adopt the curator policy ({decl}:18 names "github:example/fed-catalog-b"), re-select with `repro lock refresh --provisioning {dir}`; to keep the locked selection, change that [[policy]] back to contributor "github:example/fed-catalog-a"
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}
repro dev-env: no declared tool is provisioned (nothing is provisioned unpinned); the activated shell will resolve tools from the ambient PATH."""
  golden["locked-unavailable"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  locked-contribution-unavailable: the lock pins contributor "github:example/nobody" for package "federatedTool", but no imported catalog offers an eligible contribution from it. Eligible contributors: "github:example/fed-catalog-a", "github:example/fed-catalog-b". The lock is not re-selected by policy or by a unique eligible contribution: restore the locked catalog, or refresh the lock deliberately.
    eligible: contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
    eligible: contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:13)
    fix: the lock {lock} pins contributor "github:example/nobody" for "federatedTool", which no imported catalog offers (eligible: "github:example/fed-catalog-a", "github:example/fed-catalog-b"). Re-select with `repro lock refresh --provisioning {dir}` (rewrites the lock's provisioning records from the catalogs and the curator policy in {decl}), or restore the lock from version control if it was edited by hand
what changed since the lock was written (the locked record -> what the composed catalogs offer now):
  provisioning "federatedTool" on amd64-windows -> amd64-windows: changed (not-offered)
    the locked contributor "github:example/nobody" offers no contribution for the package in any imported catalog; offered by: "github:example/fed-catalog-a", "github:example/fed-catalog-b"
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["doubled-record"] = """
provisioning selection refused: the committed lock {lock} has `provisioning` records that cannot be read (lock two provisioning realizations are locked for package "federatedTool" on amd64-windows -> amd64-windows; a lock selects exactly one; the lock writer never produces this, and `repro lock refresh` carries the provisioning array forward rather than regenerating it (it refuses to replace a lock whose array it cannot read); restore the `provisioning` line from version control, or remove it deliberately); they are not ignored. Restore the `provisioning` line from version control, or delete it and re-select with `repro lock refresh --provisioning {dir}` (a refresh does not replace records it cannot read)."""
  golden["disagree"] = """
provisioning selection refused: the catalogs the committed lock {lock} is verified against could not be obtained: the committed lock's pin for catalog import "fed-catalog-a" disagrees with repro-catalogs.toml ({decl}:8): the declaration names commit {revA1}, the lock pins revision {revA1} for ref "main"; re-pin with `repro lock refresh --provisioning {dir}` to adopt the declaration, or change the [[import]] at {decl}:8 back to what the lock pins"""
  golden["unpinned"] = """
provisioning selection refused: the catalogs the committed lock {lock} is verified against could not be obtained: catalog import "fed-catalog-a-mirror" ({remoteMA}, {decl}:18) is declared but the committed lock pins no revision for it; re-pin with `repro lock refresh --provisioning {dir}`"""
  golden["undeclared"] = """
provisioning selection refused: the catalogs the committed lock {lock} is verified against could not be obtained: the committed lock pins catalog import "fed-catalog-b" ({remoteB} at {revB1}), which repro-catalogs.toml does not declare; re-pin with `repro lock refresh --provisioning {dir}` to drop the pin, or declare it in {decl}"""
  golden["forged-identity"] = """
provisioning selection refused: the catalogs the committed lock {lock} is verified against could not be obtained: catalog "fed-catalog-b" ({remoteB}) at {revB1} publishes interface artifact {idB}, but the committed lock pins 9999999999999999999999999999999999999999999999999999999999999999 (a stale or hand-edited pin, or a republished revision); nothing read at that revision is used. Re-pin with `repro lock refresh --provisioning {dir}`"""
  golden["build-no-declaration"] = """
provisioning selection refused: the catalogs the committed lock {lock} is verified against could not be obtained: the project declares no catalog imports: {decl} does not exist. Declare the catalogs it imports there (Federated-Catalog-Imports.md); a catalog is never inferred from a sibling directory. Create it with `schema = "reprobuild.catalog-imports.v1"` and one [[import]] table (`repo`, `remote`, and `commit` or `ref`) per catalog; the committed lock's provisioning records were selected from catalog "fed-catalog-a" ({remoteA}) at {revA1}"""
  golden["build-no-store"] = """
provisioning selection refused: the catalogs the committed lock {lock} is verified against could not be obtained: catalog "fed-catalog-b" ({remoteB}): there is no shared clone of catalog remote {remoteB} at {storeB}. Populate it with `repro ws sync` (or `git clone --bare {remoteB} {storeB}`). Discovery reads ONLY that store -- never a working checkout, a sibling directory or a develop override
    (the [[import]] of "fed-catalog-b" is at {decl}:13)"""
  golden["incomplete-coordinate"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  incomplete-catalog-coordinate: catalog import discovered at "{storeP} @ {revP}" (remote "{remoteP}") has an incomplete coordinate: revision is empty. A catalog is bound by explicit workspace/remote/revision/interface-artifact identity, never by a sibling-directory name or its position in the import list.
    fix: the catalog source supplied an incomplete coordinate for catalog "fed-packages" ({remoteP}) (no revision); every import needs `repo`, `remote` and a `commit` or `ref` in {decl}:3, and the lock a full pin: re-select with `repro lock refresh --provisioning {dir}`
  locked-contribution-unavailable: the lock pins contributor "github:example/fed-catalog-a" for package "federatedTool", but no imported catalog offers an eligible contribution for the package at all. Eligible contributors: <none>. The lock is not re-selected: restore the locked catalog, or refresh the lock deliberately.
    fix: no contribution for "federatedTool" is eligible until the incomplete-catalog-coordinate and unknown-target-interface refusal is resolved; resolve that first (the lock {lock} need not change)
  unknown-target-interface: contribution from "github:example/fed-catalog-a" in catalog fed-catalog-a|{remoteA}@{revA1}#{idA} targets package "federatedTool" (declared at repro.nim:6), but no imported catalog declares a canonical interface for it. Import the catalog that owns the interface, or remove the contribution.
    contribution: contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
    fix: first resolve the incomplete-catalog-coordinate refusal for "fed-packages": if that catalog owns the canonical interface of "federatedTool", this resolves too
    fix: in {decl}, add an [[import]] for the catalog that publishes the canonical interface of "federatedTool", or remove the [[import]] of "fed-catalog-a" ({decl}:8); then re-select with `repro lock refresh --provisioning {dir}`
  unknown-target-interface: contribution from "github:example/fed-catalog-b" in catalog fed-catalog-b|{remoteB}@{revB1}#{idB} targets package "federatedTool" (declared at repro.nim:6), but no imported catalog declares a canonical interface for it. Import the catalog that owns the interface, or remove the contribution.
    contribution: contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:13)
    fix: first resolve the incomplete-catalog-coordinate refusal for "fed-packages": if that catalog owns the canonical interface of "federatedTool", this resolves too
    fix: in {decl}, add an [[import]] for the catalog that publishes the canonical interface of "federatedTool", or remove the [[import]] of "fed-catalog-b" ({decl}:13); then re-select with `repro lock refresh --provisioning {dir}`
what changed since the lock was written (the locked record -> what the composed catalogs offer now):
  provisioning "federatedTool" on amd64-windows -> amd64-windows: changed
    contributor "github:example/fed-catalog-a" offers it at interface {fp} from catalog fed-catalog-a|{remoteA}@{revA1}#{idA}
    the composed catalogs refused (see the refusals above), so the locked record could not be compared further
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["missing-catalog"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  locked-contribution-unavailable: the lock pins contributor "github:example/fed-catalog-a" for package "federatedTool", but no imported catalog offers an eligible contribution for the package at all. Eligible contributors: <none>. The lock is not re-selected: restore the locked catalog, or refresh the lock deliberately.
    fix: no contribution for "federatedTool" is eligible until the missing-catalog and unknown-target-interface refusal is resolved; resolve that first (the lock {lock} need not change)
  missing-catalog: catalog fed-packages|{remoteP}@{revP}#{idP} was declared but not found (discovered at "{storeP} @ {revP}"); no interface artifact is available to compose. Pin the catalog in the workspace manifest, or remove the import.
    fix: fetch catalog "fed-packages" ({remoteP}) at {revP} into the workspace's shared clone (`repro ws sync`), or remove its [[import]] ({decl}:3); then re-select with `repro lock refresh --provisioning {dir}`
  unknown-target-interface: contribution from "github:example/fed-catalog-a" in catalog fed-catalog-a|{remoteA}@{revA1}#{idA} targets package "federatedTool" (declared at repro.nim:6), but no imported catalog declares a canonical interface for it. Import the catalog that owns the interface, or remove the contribution.
    contribution: contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
    fix: first resolve the missing-catalog refusal for "fed-packages": if that catalog owns the canonical interface of "federatedTool", this resolves too
    fix: in {decl}, add an [[import]] for the catalog that publishes the canonical interface of "federatedTool", or remove the [[import]] of "fed-catalog-a" ({decl}:8); then re-select with `repro lock refresh --provisioning {dir}`
  unknown-target-interface: contribution from "github:example/fed-catalog-b" in catalog fed-catalog-b|{remoteB}@{revB1}#{idB} targets package "federatedTool" (declared at repro.nim:6), but no imported catalog declares a canonical interface for it. Import the catalog that owns the interface, or remove the contribution.
    contribution: contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:13)
    fix: first resolve the missing-catalog refusal for "fed-packages": if that catalog owns the canonical interface of "federatedTool", this resolves too
    fix: in {decl}, add an [[import]] for the catalog that publishes the canonical interface of "federatedTool", or remove the [[import]] of "fed-catalog-b" ({decl}:13); then re-select with `repro lock refresh --provisioning {dir}`
what changed since the lock was written (the locked record -> what the composed catalogs offer now):
  provisioning "federatedTool" on amd64-windows -> amd64-windows: changed
    no imported catalog declares a canonical interface for the package
    contributor "github:example/fed-catalog-a" offers it at interface {fp} from catalog fed-catalog-a|{remoteA}@{revA1}#{idA}
    the composed catalogs refused (see the refusals above), so the locked record could not be compared further
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["identity-conflict"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  catalog-identity-conflict: catalog coordinate fed-packages|{remoteP}@{revP}#{idP} was imported with 2 different contents; one coordinate names exactly one interface-artifact identity. Discovered at: {storeP} @ {revP}; elsewhere. Re-extract the catalog's interface artifacts, or give the differing checkout its own revision.
    fix: catalog "fed-packages" ({remoteP}) at {revP} was read with different contents; keep one [[import]] of "fed-packages" in {decl} ({decl}:3), then re-select with `repro lock refresh --provisioning {dir}`
  locked-contribution-unavailable: the lock pins contributor "github:example/fed-catalog-a" for package "federatedTool", but no imported catalog offers an eligible contribution for the package at all. Eligible contributors: <none>. The lock is not re-selected: restore the locked catalog, or refresh the lock deliberately.
    fix: no contribution for "federatedTool" is eligible until the catalog-identity-conflict and unknown-target-interface refusal is resolved; resolve that first (the lock {lock} need not change)
  unknown-target-interface: contribution from "github:example/fed-catalog-a" in catalog fed-catalog-a|{remoteA}@{revA1}#{idA} targets package "federatedTool" (declared at repro.nim:6), but no imported catalog declares a canonical interface for it. Import the catalog that owns the interface, or remove the contribution.
    contribution: contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
    fix: first resolve the catalog-identity-conflict refusal for "fed-packages": if that catalog owns the canonical interface of "federatedTool", this resolves too
    fix: in {decl}, add an [[import]] for the catalog that publishes the canonical interface of "federatedTool", or remove the [[import]] of "fed-catalog-a" ({decl}:8); then re-select with `repro lock refresh --provisioning {dir}`
  unknown-target-interface: contribution from "github:example/fed-catalog-b" in catalog fed-catalog-b|{remoteB}@{revB1}#{idB} targets package "federatedTool" (declared at repro.nim:6), but no imported catalog declares a canonical interface for it. Import the catalog that owns the interface, or remove the contribution.
    contribution: contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:13)
    fix: first resolve the catalog-identity-conflict refusal for "fed-packages": if that catalog owns the canonical interface of "federatedTool", this resolves too
    fix: in {decl}, add an [[import]] for the catalog that publishes the canonical interface of "federatedTool", or remove the [[import]] of "fed-catalog-b" ({decl}:13); then re-select with `repro lock refresh --provisioning {dir}`
what changed since the lock was written (the locked record -> what the composed catalogs offer now):
  provisioning "federatedTool" on amd64-windows -> amd64-windows: changed
    contributor "github:example/fed-catalog-a" offers it at interface {fp} from catalog fed-catalog-a|{remoteA}@{revA1}#{idA}
    the composed catalogs refused (see the refusals above), so the locked record could not be compared further
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["repinned"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  contribution-changed: the locked provisioning realization of package "federatedTool" selects contribution {cfA1} from "github:example/fed-catalog-a", which is now {cfA2}; the package interface is unchanged (typechecking stays valid), but the locked realization must be refreshed (the lock pins contributor "github:example/fed-catalog-a"; the composed catalogs offer contributor "github:example/fed-catalog-a" at interface {fp}, contribution {cfA2}; not re-selected)
    fix: the lock {lock} no longer describes what the catalogs it pins offer; re-select with `repro lock refresh --provisioning {dir}` to adopt what they offer now (it prints what changed), or restore the lock from version control if it was edited by hand
what changed since the lock was written (the locked record -> what the composed catalogs offer now):
  provisioning "federatedTool" on amd64-windows -> amd64-windows: changed (contribution-changed, catalog-changed)
    contribution changed (realization-only: the interface is unchanged, so typechecking stays valid): {cfA1} -> {cfA2}
      cause (from the two contribution identities, each verified to reproduce its record's fingerprint):
        - provider identity: {provA1} -> {provA2}
    catalog revision changed: "{revA1}" -> "{revA2}"
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["repinned-unreadable"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  contribution-changed: the locked provisioning realization of package "federatedTool" selects contribution {cfA1} from "github:example/fed-catalog-a", which is now {cfA2}; the package interface is unchanged (typechecking stays valid), but the locked realization must be refreshed (the lock pins contributor "github:example/fed-catalog-a"; the composed catalogs offer contributor "github:example/fed-catalog-a" at interface {fp}, contribution {cfA2}; not re-selected)
    fix: the lock {lock} no longer describes what the catalogs it pins offer; re-select with `repro lock refresh --provisioning {dir}` to adopt what they offer now (it prints what changed), or restore the lock from version control if it was edited by hand
what changed since the lock was written (the locked record -> what the composed catalogs offer now):
  provisioning "federatedTool" on amd64-windows -> amd64-windows: changed (contribution-changed, catalog-changed)
    contribution changed (realization-only: the interface is unchanged, so typechecking stays valid): {cfA1} -> {cfA2}
      cause: not determinable from the records -- a lock records the contribution fingerprint, not the metadata it was computed from, and no identity reproducing the fingerprint of the locked contribution was supplied
      no recorded fingerprint input changed (the interface, realization lock identity, family and integrity are the same), so the change is in metadata the lock does not record: realization fields, the provider identity or a dependency
    catalog revision changed: "7777777777777777777777777777777777777777" -> "{revA2}"
  the published catalogs that would explain this field by field could not be read at the recorded revisions:
    catalog "fed-catalog-a" ({remoteA}) at 7777777777777777777777777777777777777777: the pinned commit is not available in the shared clone {storeA} (object 7777777777777777777777777777777777777777 (commit) cannot be read from {storeA}: fatal: git cat-file 7777777777777777777777777777777777777777: bad file). Fetch it with `git --git-dir={storeA} fetch origin 7777777777777777777777777777777777777777` or `repro ws sync`; another revision, a checkout or a sibling directory is never used instead
    fix: fetch each revision into the workspace's shared clone (`repro ws sync`) and run the command again
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["diff"] = """
provisioning "federatedTool" on amd64-windows -> amd64-windows: changed (contribution-changed, catalog-changed)
  contribution changed (realization-only: the interface is unchanged, so typechecking stays valid): {cfA1} -> {cfA2}
    cause (from the two contribution identities, each verified to reproduce its record's fingerprint):
      - provider identity: {provA1} -> {provA2}
  catalog revision changed: "{revA1}" -> "{revA2}""""
  golden["diff-blind"] = """
provisioning "federatedTool" on amd64-windows -> amd64-windows: changed (contribution-changed, catalog-changed)
  contribution changed (realization-only: the interface is unchanged, so typechecking stays valid): {cfA1} -> {cfA2}
    cause: not determinable from the records -- a lock records the contribution fingerprint, not the metadata it was computed from, and no identity reproducing the fingerprint of the locked contribution or the new contribution was supplied
    no recorded fingerprint input changed (the interface, realization lock identity, family and integrity are the same), so the change is in metadata the lock does not record: realization fields, the provider identity or a dependency
  catalog revision changed: "{revA1}" -> "{revA2}"
the published catalogs that would explain this field by field could not be read at the recorded revisions:
  catalog "fed-catalog-a" ({remoteA}) at {revFirst}: there is no shared clone of catalog remote {remoteA} at {storeA}. Populate it with `repro ws sync` (or `git clone --bare {remoteA} {storeA}`). Discovery reads ONLY that store -- never a working checkout, a sibling directory or a develop override
  catalog "fed-catalog-a" ({remoteA}) at {revSecond}: there is no shared clone of catalog remote {remoteA} at {storeA}. Populate it with `repro ws sync` (or `git clone --bare {remoteA} {storeA}`). Discovery reads ONLY that store -- never a working checkout, a sibling directory or a develop override
  fix: fetch each revision into the workspace's shared clone (`repro ws sync`) and run the command again"""

  golden["crafted-garbage"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-garbage} cannot be composed:
      published artifact published-interfaces/fedCatalogA.rbsz is not a readable interface artifact: unsupported interface envelope version
      fix: pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["crafted-forged"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-forged} cannot be composed:
      published artifact published-interfaces/fedCatalogA.rbsz is not a readable interface artifact: interface fingerprint mismatch
      fix: pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["crafted-imported"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-imported} cannot be composed:
      published artifact published-interfaces/fedCatalogA.rbsz: contribution from "github:example/fed-catalog-a" for package "federatedTool" is IMPORTED (re-exported from another catalog); a catalog publishes only its own records
      fix: pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["crafted-stray"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-stray} cannot be composed:
      `published-interfaces/notes.txt` (mode 100644) is not a regular `*.rbsz` file; the directory holds published artifacts and nothing else
      fix: pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["crafted-empty"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-empty} cannot be composed:
      `published-interfaces/` is empty
      fix: pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["crafted-duplicate"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-duplicate} cannot be composed:
      `published-interfaces/fedCatalogA.rbsz` appears more than once in the tree
      fix: pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["crafted-malformed"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-malformed}: tree f6f80def4ffad1e1606cf7f5a3dd72638aa20b8a is malformed. Pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["crafted-not-dir"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-not-dir}: `published-interfaces` is not a directory (mode 100644). Pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["crafted-no-tree"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_crafted-no-tree}: the commit object does not start with its tree. Pin a revision of "fed-catalog-a" that publishes valid interface artifacts (the `commit` or `ref` of its [[import]] in repro-catalogs.toml), or have its publisher regenerate and commit `published-interfaces/`
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["absent-commit"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {rev_absent-commit}: the pinned commit is not available in the shared clone {storeA} (object {rev_absent-commit} (commit) cannot be read from {storeA}: fatal: git cat-file {rev_absent-commit}: bad file). Fetch it with `git --git-dir={storeA} fetch origin {rev_absent-commit}` or `repro ws sync`; another revision, a checkout or a sibling directory is never used instead
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["remote-clash"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: {decl}: one remote is one catalog import: imports "fed-catalog-a" (line 8) and "fed-catalog-a-again" (line 18) name one remote (example.invalid/dx/fed-catalog-a). Keep one [[import]] per repository and remove the other"""
  golden["asserted-identity"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {revA1} publishes interface artifact {idA}, but repro-catalogs.toml asserts 9999999999999999999999999999999999999999999999999999999999999999 ({decl}:8); correct or remove the `interface_artifact` assertion there, or pin the revision that publishes it"""
  golden["ref-symbolic"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): refs/heads/follow is a symbolic ref (to refs/heads/main); name the branch or tag itself, or pin a `commit`, in its [[import]] in repro-catalogs.toml
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["ref-both"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): "split" is both a branch ({revNothing}) and a tag ({revA1}) naming different commits; pin a `commit` instead (in its [[import]] in repro-catalogs.toml)
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["ref-blob"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): refs/tags/blobtag does not name a commit (it names a blob); name a branch or tag that points at a commit, or pin a `commit`, in its [[import]] in repro-catalogs.toml
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["store-no-origin"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): the shared clone at {storeA} has no remote.origin.url, so nothing shows it is a clone of {remoteA}. It is not read for this catalog. Move it aside and re-create it with `git clone --bare {remoteA} {storeA}` (or `repro ws sync`)
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["store-two-origins"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): the shared clone at {storeA} names 2 origin URL(s) (https://example.invalid/x, {remoteA}) that a fetch would use as 2 URL(s) (https://example.invalid/x, {remoteA}); a store that is a clone of {remoteA} names exactly one. It is not read for this catalog. Move it aside and re-create it with `git clone --bare {remoteA} {storeA}` (or `repro ws sync`)
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["store-other-origin"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): the shared clone at {storeA} is a clone of {remoteB}, not of catalog remote {remoteA} (two remotes share one cache directory name, or the store's configuration redirects it); it is not read for this catalog. Move it aside and re-create it with `git clone --bare {remoteA} {storeA}` (or `repro ws sync`)
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["store-ambiguous-origin"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): the shared clone at {storeA} is a clone of "https://evil.invalid?@example.invalid/dx/fed-catalog-a", which contains whitespace, a control character, '?', '#' or a backslash, which make the host it names depend on who parses it; it is not read for catalog remote {remoteA}. Move it aside and re-create it with `git clone --bare {remoteA} {storeA}` (or `repro ws sync`)
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["store-insteadof"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): the shared clone at {storeA} fetches (after url.*.insteadOf) from https://evil.invalid/dx/fed-catalog-a, not from catalog remote {remoteA} (two remotes share one cache directory name, or the store's configuration redirects it); it is not read for this catalog. Move it aside and re-create it with `git clone --bare {remoteA} {storeA}` (or `repro ws sync`)
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["store-sha256"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}): the shared clone at {shaStore} uses the sha256 object format; catalog discovery re-hashes SHA-1 objects only and refuses the rest (a false refusal: SHA-256 repositories are not supported yet)
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  golden["incumbent-same-contributor"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  unresolved-contribution-ambiguity: package "federatedTool" (interface {fp}) has 2 eligible provisioning contributions from contributor "github:example/fed-catalog-a", which the curator policy selects; a contributor id names one publisher, so the policy cannot choose between the catalogs that offer it, and import order is never a selection rule (Provisioning-Contributions.md, Resolution). Candidates: contributor "github:example/fed-catalog-a" from catalog fed-catalog-a-mirror|{remoteMA}@{revMA}#{idA} declared at repro.nim:6; contributor "github:example/fed-catalog-a" from catalog fed-catalog-a|{remoteA}@{revA1}#{idA} declared at repro.nim:6. Import only the catalog that should offer it.
      candidates:
        contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a-mirror" ({remoteMA}) at {revMA}, declared at repro.nim:6 (imported at {decl}:18)
        contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
      fix: contributor "github:example/fed-catalog-a" is offered by 2 imported catalogs: "fed-catalog-a-mirror" ({decl}:18), "fed-catalog-a" ({decl}:8). A contributor id names one publisher and no policy can choose between two catalogs that claim it: remove the [[import]] of the catalog that should not offer it from {decl} (or pin it at a revision that does not), then re-select with `repro lock refresh --provisioning {dir}`"""
  golden["incumbent-ambiguous"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  unresolved-contribution-ambiguity: package "federatedTool" (interface {fp}) has 2 eligible provisioning contributions and no lock or curator policy selects one; import order is never a selection rule (Provisioning-Contributions.md, Resolution). Candidates: contributor "github:example/fed-catalog-a" from catalog fed-catalog-a|{remoteA}@{revA1}#{idA} declared at repro.nim:6; contributor "github:example/fed-catalog-b" from catalog fed-catalog-b|{remoteB}@{revB1}#{idB} declared at repro.nim:6. Pin one with an explicit selection.
      candidates:
        contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
        contributor "github:example/fed-catalog-b" from catalog "fed-catalog-b" ({remoteB}) at {revB1}, declared at repro.nim:6 (imported at {decl}:13)
      fix: in {decl}, add a curator policy naming one of "github:example/fed-catalog-a", "github:example/fed-catalog-b":
          [[policy]]
          package = "federatedTool"
          contributor = "github:example/fed-catalog-a"
        then re-select with `repro lock refresh --provisioning {dir}`
  note: re-selection does not take the incumbent lock's own pins as a selection rule (they are what is being re-derived); the incumbent pins "federatedTool" -> "github:example/fed-catalog-a". Name the contributor in the curator policy to keep it."""
  golden["record-revision-only"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  catalog-changed: the lock pins contributor "github:example/fed-catalog-a" for package "federatedTool" from catalog fed-catalog-a|{remoteA}@7777777777777777777777777777777777777777#{idA}, but the composed catalogs offer it from catalog fed-catalog-a|{remoteA}@{revA1}#{idA}. The lock pins the catalog revision; refresh the lock deliberately.
    fix: the lock {lock} no longer describes what the catalogs it pins offer; re-select with `repro lock refresh --provisioning {dir}` to adopt what they offer now (it prints what changed), or restore the lock from version control if it was edited by hand
what changed since the lock was written (the locked record -> what the composed catalogs offer now):
  provisioning "federatedTool" on amd64-windows -> amd64-windows: changed (catalog-changed)
    contribution fingerprint unchanged: {cfA1} (the same contribution, byte for byte)
    catalog revision changed: "7777777777777777777777777777777777777777" -> "{revA1}"
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""
  golden["evidence-filtered"] = """
provisioning selection refused: the committed lock {lock} does not resolve against the composed catalogs; the lock is not relaxed to an unpinned selection:
  contribution-changed: the locked provisioning realization of package "federatedTool" selects contribution 0000000000000000000000000000000000000000000000000000000000000000 from "github:example/fed-catalog-a", which is now {cfA1}; the package interface is unchanged (typechecking stays valid), but the locked realization must be refreshed (the lock pins contributor "github:example/fed-catalog-a"; the composed catalogs offer contributor "github:example/fed-catalog-a" at interface {fp}, contribution {cfA1}; not re-selected)
    fix: the lock {lock} no longer describes what the catalogs it pins offer; re-select with `repro lock refresh --provisioning {dir}` to adopt what they offer now (it prints what changed), or restore the lock from version control if it was edited by hand
what changed since the lock was written (the locked record -> what the composed catalogs offer now):
  provisioning "federatedTool" on amd64-windows -> amd64-windows: changed (contribution-changed, catalog-changed)
    contribution changed (realization-only: the interface is unchanged, so typechecking stays valid): 0000000000000000000000000000000000000000000000000000000000000000 -> {cfA1}
      cause: not determinable from the records -- a lock records the contribution fingerprint, not the metadata it was computed from, and no identity reproducing the fingerprint of the locked contribution was supplied
      no recorded fingerprint input changed (the interface, realization lock identity, family and integrity are the same), so the change is in metadata the lock does not record: realization fields, the provider identity or a dependency
    catalog revision changed: "7777777777777777777777777777777777777777" -> "{revA1}"
  the published catalogs that would explain this field by field could not be read at the recorded revisions:
    catalog "fed-catalog-a" ({remoteA}) at 7777777777777777777777777777777777777777: the pinned commit is not available in the shared clone {storeA} (object 7777777777777777777777777777777777777777 (commit) cannot be read from {storeA}: fatal: git cat-file 7777777777777777777777777777777777777777: bad file). Fetch it with `git --git-dir={storeA} fetch origin 7777777777777777777777777777777777777777` or `repro ws sync`; another revision, a checkout or a sibling directory is never used instead
    fix: fetch each revision into the workspace's shared clone (`repro ws sync`) and run the command again
to re-select explicitly (rewrites the lock's provisioning records and prints this diff; nothing re-selects silently):
  repro lock refresh --provisioning {dir}"""

  golden["store-substituted"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  the catalogs to re-select from could not be obtained: catalog "fed-catalog-a" ({remoteA}) at {revA1} cannot be composed:
      object {blobA} (blob) read from {looseStore} hashes to {otherBlob}, not to the id it was requested by: the object store is corrupt or was tampered with, and nothing read from it is used. Move the shared clone {looseStore} aside and re-create it (`repro ws sync`)
      (the [[import]] of "fed-catalog-a" is at {decl}:8)"""
  # No re-selection note: naming the incumbent's contributor in a policy
  # cannot choose between the two catalogs that offer it.
  golden["same-contributor-no-policy"] = """
repro lock refresh --provisioning: re-selection refused; {lock} was not written:
  unresolved-contribution-ambiguity: package "federatedTool" (interface {fp}) has 2 eligible provisioning contributions, all from contributor "github:example/fed-catalog-a"; a curator policy names a contributor, not one of its contributions, so none can choose between them, and import order is never a selection rule (Provisioning-Contributions.md, Resolution). Candidates: contributor "github:example/fed-catalog-a" from catalog fed-catalog-a-mirror|{remoteMA}@{revMA}#{idA} declared at repro.nim:6; contributor "github:example/fed-catalog-a" from catalog fed-catalog-a|{remoteA}@{revA1}#{idA} declared at repro.nim:6. Import only the catalog that should offer it.
      candidates:
        contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a-mirror" ({remoteMA}) at {revMA}, declared at repro.nim:6 (imported at {decl}:13)
        contributor "github:example/fed-catalog-a" from catalog "fed-catalog-a" ({remoteA}) at {revA1}, declared at repro.nim:6 (imported at {decl}:8)
      fix: contributor "github:example/fed-catalog-a" is offered by 2 imported catalogs: "fed-catalog-a-mirror" ({decl}:13), "fed-catalog-a" ({decl}:8). A contributor id names one publisher and no policy can choose between two catalogs that claim it: remove the [[import]] of the catalog that should not offer it from {decl} (or pin it at a revision that does not), then re-select with `repro lock refresh --provisioning {dir}`"""

suite "federated catalog diagnostics are actionable":
  loadGolden()
  when defined(windows):
    putEnv("PATH", getEnv("SystemRoot", r"C:\Windows") / "System32" & ";" &
      getEnv("PATH"))
  putEnv("REPRO_CACHE_DISABLE", "1")
  let top = createTempDir("repro-diag-", "")
  var env = enterHermeticEnvironment(top)
  consumersRoot = top / "consumers"
  let archiveA = buildFixtureArchive(top, "a1", "diag-tool-from-a",
    FedToolTopDir, FedToolExecutable)
  let archiveB = buildFixtureArchive(top, "b1", "diag-tool-from-b",
    FedToolTopDir, FedToolExecutable)
  let w = newStandardWorld(top, "dx", archiveA, archiveB, env.clonesRoot)
  let fp = w.toolFingerprint
  let defs = @[consumerDef(FedContributorA, archiveA, fp),
    consumerDef(FedContributorB, archiveB, fp)]
  # A mirror of catalog A under another remote (the same generated
  # publication: the same contributor id offered twice) and a mirror of the
  # interface catalog (a second owner of the canonical interface).
  let mirrorA = initCatalogRepo(top / "dx", "fed-catalog-a-mirror",
    fedRemote("dx", "fed-catalog-a-mirror"))
  let revMirrorA = mirrorA.publishRevision(fedCatalogSource("fedCatalogA",
    [fedContribution(FedContributorA, archiveA, fp)]), "mirror A").revision
  discard mirrorA.syncSharedClone(env.clonesRoot)
  let mirrorP = initCatalogRepo(top / "dx", "fed-packages-mirror",
    fedRemote("dx", "fed-packages-mirror"))
  let revMirrorP = mirrorP.publishRevision(canonicalToolSource(FedToolPackage,
    FedToolExecutable), "mirror interfaces").revision
  discard mirrorP.syncSharedClone(env.clonesRoot)
  # A second interface revision on the interface catalog's branch v2: the
  # tool gained a flag, so the contributions pinned to v1 are incompatible.
  let p2 = w.packages.publishRevision(
    canonicalToolSource(FedToolPackage, FedToolExecutable).replace(
      "        flag verbose, bool\n",
      "        flag verbose, bool\n        flag quiet, bool\n"),
    "interface v2", branch = "v2")
  discard w.packages.syncSharedClone(env.clonesRoot)
  let fp2 = fingerprintHexOf(p2.files[0].artifact)

  proc identity(files: seq[PublishedArtifactFile]): string =
    catalogArtifactIdentity(files.mapIt(it.artifact))
  proc providerAt(repo: CatalogRepo; rev: string): string =
    catalogProviderIdentity("sha1",
      rootTreeOf(sharedCloneOf(env.clonesRoot, repo.remote), rev))

  var base = initTable[string, string]()
  base["fp"] = fp
  base["fp2"] = fp2
  base["remoteP"] = w.packages.remote
  base["remoteA"] = w.a.remote
  base["remoteB"] = w.b.remote
  base["remoteMA"] = mirrorA.remote
  base["remoteMP"] = mirrorP.remote
  base["revP"] = w.revPackages
  base["revP2"] = p2.revision
  base["revA1"] = w.revA1
  base["revB1"] = w.revB1
  base["revMA"] = revMirrorA
  base["revMP"] = revMirrorP
  base["idP"] = identity(w.publishedPackages)
  base["idP2"] = identity(p2.files)
  base["idA"] = identity(w.publishedA1)
  base["idB"] = identity(w.publishedB1)
  base["storeP"] = sharedCloneOf(env.clonesRoot, w.packages.remote)
  base["storeA"] = sharedCloneOf(env.clonesRoot, w.a.remote)
  base["storeB"] = sharedCloneOf(env.clonesRoot, w.b.remote)
  base["shaA"] = archiveA.sha256
  base["shaB"] = archiveB.sha256
  base["provA1"] = providerAt(w.a, w.revA1)
  base["cfA1"] = contributionFingerprint(ContributionIdentity(
    contribution: recordOfPublished(w.publishedA1),
    providerIdentity: base["provA1"]), noContributionResolver).hex

  proc ctx(dir: string): Table[string, string] =
    result = base
    result["dir"] = dir
    result["decl"] = dir / CatalogImportsFileName
    result["lock"] = dir / "repro.lock"

  test "an ambiguous selection names each candidate and the [[policy]] that resolves it":
    let dir = consumer("ambiguous", w.standardImports(), policy = @[])
    check expectText("ambiguous", refreshRefusal(dir), ctx(dir))
    # The candidates are listed in one order whatever the declaration's.
    var reversed = w.standardImports()
    reversed = @[reversed[2], reversed[1], reversed[0]]
    let back = consumer("ambiguous-reversed", reversed, policy = @[])
    let text = refreshRefusal(back)
    let lines = text.splitLines().filterIt(it.strip().startsWith(
      "contributor \""))
    check lines.len == 2
    check lines.mapIt(it.strip().split('"')[1]) ==
      @[FedContributorA, FedContributorB]

  test "one contributor offered by two catalogs names both imports to remove one":
    var specs = w.standardImports()
    specs.add(ImportSpec(repo: "fed-catalog-a-mirror", remote: mirrorA.remote,
      commit: revMirrorA))
    let dir = consumer("same-contributor", specs)
    check expectText("same-contributor", refreshRefusal(dir), ctx(dir))

  test "two owners of one canonical interface name both imports":
    var specs = w.standardImports()
    specs.add(ImportSpec(repo: "fed-packages-mirror", remote: mirrorP.remote,
      commit: revMirrorP))
    let dir = consumer("duplicate-owner", specs)
    check expectText("duplicate-owner", refreshRefusal(dir), ctx(dir))

  test "a contribution pinned to another interface names both catalogs and the edits":
    var specs = w.standardImports()
    specs[0].gitRef = "v2"
    let dir = consumer("incompatible", specs)
    check expectText("incompatible", refreshRefusal(dir), ctx(dir))

  test "a contribution whose interface no catalog owns names the import to add or remove":
    let dir = consumer("unknown-target", w.standardImports()[1 .. 2])
    check expectText("unknown-target", refreshRefusal(dir), ctx(dir))

  test "an unsatisfied policy names its table and the eligible contributors once each":
    var specs = w.standardImports()
    specs.add(ImportSpec(repo: "fed-catalog-a-mirror", remote: mirrorA.remote,
      commit: revMirrorA))
    let dir = consumer("unsatisfied", specs,
      policy = @[(FedToolPackage, "github:example/nobody")])
    check expectText("unsatisfied", refreshRefusal(dir), ctx(dir))

  test "a contradictory policy names both tables":
    let dir = consumer("contradictory", w.standardImports(),
      policy = @[(FedToolPackage, FedContributorB),
        (FedToolPackage, FedContributorA)])
    check expectText("contradictory", refreshRefusal(dir), ctx(dir))

  test "discovery refusals at re-selection name the catalog, the import and the remedy":
    # No declaration.
    block:
      let dir = consumer("no-declaration", w.standardImports())
      removeFile(dir / CatalogImportsFileName)
      check expectText("no-declaration", refreshRefusal(dir), ctx(dir))
    # A declaration the reader refuses.
    block:
      let dir = consumer("bad-declaration", w.standardImports())
      writeFile(dir / CatalogImportsFileName,
        readFile(dir / CatalogImportsFileName).replace(
          "ref = \"main\"\n", "ref = \"main\"\nbranch = \"main\"\n"))
      check expectText("bad-declaration", refreshRefusal(dir), ctx(dir))
    # A ref the shared clone does not have.
    block:
      var specs = w.standardImports()
      specs[1].gitRef = "no-such-branch"
      let dir = consumer("no-ref", specs)
      check expectText("no-ref", refreshRefusal(dir), ctx(dir))
    # A commit that publishes nothing (crafted: no publisher writes it).
    block:
      let nothing = w.a.publishCommit(@[], "nothing", branch = "nothing")
      discard w.a.syncSharedClone(env.clonesRoot)
      var specs = w.standardImports()
      specs[1].gitRef = ""
      specs[1].commit = nothing
      let dir = consumer("no-publication", specs)
      var t = ctx(dir)
      t["revNothing"] = nothing
      check expectText("no-publication", refreshRefusal(dir), t)
    # The shared clone is missing.
    block:
      let dir = consumer("no-store", w.standardImports())
      let bare = sharedCloneOf(env.clonesRoot, w.a.remote)
      moveDir(bare, bare & ".aside")
      try:
        check expectText("no-store", refreshRefusal(dir), ctx(dir))
      finally:
        moveDir(bare & ".aside", bare)

  test "build refusals name the lock, the declaration line and the command":
    let good = consumer("build", w.standardImports())
    check refresh(good) == 0
    let goodLock = readFile(good / "repro.lock")
    let goodDecl = readFile(good / CatalogImportsFileName)
    check buildRefusal(good, defs) == ""
    let t = ctx(good)
    # The curator policy now contradicts the lock. What ``repro build`` and
    # dev-env activation print around the same refusal.
    writeDeclaration(good, w.standardImports(),
      @[(FedToolPackage, FedContributorB)])
    let contradicts = buildRefusal(good, defs)
    check expectText("policy-contradicts-lock", contradicts, t)
    check expectText("repro-build", reproBuildErrorText(contradicts), t)
    check expectText("dev-env", devEnvProvisioningRefusalText(contradicts), t)
    # The lock pins a contributor no catalog offers (edited by hand).
    writeDeclaration(good, w.standardImports(), @[])
    writeFile(good / "repro.lock", goodLock.replace(
      "contributor = \"" & FedContributorA & "\"",
      "contributor = \"github:example/nobody\""))
    check expectText("locked-unavailable", buildRefusal(good, defs), t)
    # The lock carries the record twice (edited by hand).
    block:
      var doubled = ""
      for line in goodLock.splitLines(keepEol = true):
        if line.startsWith(ProvisioningLockKey & " = [") and
            line.strip().endsWith("]"):
          let inner = line.strip()[(ProvisioningLockKey & " = [").len ..
            ^2]
          doubled.add(ProvisioningLockKey & " = [" & inner & ", " & inner &
            "]\n")
        else:
          doubled.add(line)
      writeFile(good / "repro.lock", doubled)
      writeDeclaration(good, w.standardImports(),
        @[(FedToolPackage, FedContributorA)])
      check expectText("doubled-record", buildRefusal(good, defs), t)
    writeFile(good / "repro.lock", goodLock)
    writeFile(good / CatalogImportsFileName, goodDecl)
    check buildRefusal(good, defs) == ""
    # Pins and declaration disagree: a ref turned into a commit, an import
    # without a pin, a pin without an import.
    var specs = w.standardImports()
    specs[1].gitRef = ""
    specs[1].commit = w.revA1
    writeDeclaration(good, specs, @[(FedToolPackage, FedContributorA)])
    check expectText("disagree", buildRefusal(good, defs), t)
    specs = w.standardImports()
    specs.add(ImportSpec(repo: "fed-catalog-a-mirror", remote: mirrorA.remote,
      commit: revMirrorA))
    writeDeclaration(good, specs, @[(FedToolPackage, FedContributorA)])
    check expectText("unpinned", buildRefusal(good, defs), t)
    writeDeclaration(good, w.standardImports()[0 .. 1],
      @[(FedToolPackage, FedContributorA)])
    check expectText("undeclared", buildRefusal(good, defs), t)
    # A hand-edited interface-artifact pin.
    writeFile(good / CatalogImportsFileName, goodDecl)
    writeFile(good / "repro.lock", goodLock.replace(base["idB"],
      repeat('9', 64)))
    check expectText("forged-identity", buildRefusal(good, defs), t)
    writeFile(good / "repro.lock", goodLock)
    # No declaration at all, while the lock has records.
    removeFile(good / CatalogImportsFileName)
    check expectText("build-no-declaration", buildRefusal(good, defs), t)
    writeFile(good / CatalogImportsFileName, goodDecl)
    # The shared clone of a pinned catalog is missing.
    let bare = sharedCloneOf(env.clonesRoot, w.b.remote)
    moveDir(bare, bare & ".aside")
    try:
      check expectText("build-no-store", buildRefusal(good, defs), t)
    finally:
      moveDir(bare & ".aside", bare)
    check buildRefusal(good, defs) == ""
    # The refusal texts name the consumer's own files; none of that reaches
    # the lock.
    check top notin readFile(good / "repro.lock")
    check top.replace('\\', '/') notin readFile(good / "repro.lock")

  test "every discovery refusal names the catalog, the import and the remedy":
    ## Each refusal ``catalog_discovery`` can raise while re-selecting,
    ## through ``repro lock refresh --provisioning``: crafted stores and
    ## objects where a publisher could not produce the input.
    let bareA = sharedCloneOf(env.clonesRoot, w.a.remote)
    let artifactBlob = blobIdAt(bareA, w.revA1,
      "published-interfaces/fedCatalogA.rbsz")
    proc pinA(rev: string): seq[ImportSpec] =
      result = w.standardImports()
      result[1].gitRef = ""
      result[1].commit = rev
    proc pubCommit(entries: seq[TreeEntrySpec]): string =
      let pub = writeRawTree(bareA, entries)
      commitTree(bareA, writeTree(bareA, [TreeEntrySpec(mode: "040000",
        kind: "tree", oid: pub, name: "published-interfaces")]), "crafted")
    let ok = TreeEntrySpec(mode: "100644", kind: "blob", oid: artifactBlob,
      name: "fedCatalogA.rbsz")
    proc encoded(artifact: ProjectInterfaceArtifact): string =
      for b in encodeProjectInterfaceArtifact(artifact): result.add(char(b))
    var forged = w.publishedA1[0].artifact
    forged.projectInterface.provisioningContributions[0].
      tarballProvisioning[0].url = "https://example.invalid/forged.tar.gz"
    var imported = w.publishedA1[0].artifact
    imported.projectInterface.provisioningContributions[0].imported = true
    imported = artifactFor(imported.projectInterface)
    var t = ctx("")
    var scenarios: seq[(string, seq[ImportSpec])] = @[]
    template crafted(name: string; rev: string) =
      t["rev_" & name] = rev
      scenarios.add((name, pinA(rev)))
    crafted("crafted-garbage", pubCommit(@[TreeEntrySpec(mode: "100644",
      kind: "blob", oid: writeBlob(bareA, "RBSZ but not an artifact"),
      name: "fedCatalogA.rbsz")]))
    crafted("crafted-forged", pubCommit(@[TreeEntrySpec(mode: "100644",
      kind: "blob", oid: writeBlob(bareA, encoded(forged)),
      name: "fedCatalogA.rbsz")]))
    crafted("crafted-imported", pubCommit(@[TreeEntrySpec(mode: "100644",
      kind: "blob", oid: writeBlob(bareA, encoded(imported)),
      name: "fedCatalogA.rbsz")]))
    crafted("crafted-stray", pubCommit(@[ok, TreeEntrySpec(mode: "100644",
      kind: "blob", oid: artifactBlob, name: "notes.txt")]))
    crafted("crafted-empty", pubCommit(@[]))
    crafted("crafted-duplicate", pubCommit(@[ok, ok]))
    crafted("crafted-malformed", commitTree(bareA, writeTree(bareA,
      [TreeEntrySpec(mode: "040000", kind: "tree", oid: writeRawObject(bareA,
        "tree", "100644 x.rbsz\0\x01\x02"), name: "published-interfaces")]),
      "malformed"))
    crafted("crafted-not-dir", commitTree(bareA, writeTree(bareA,
      [TreeEntrySpec(mode: "100644", kind: "blob", oid: artifactBlob,
        name: "published-interfaces")]), "not a dir"))
    crafted("crafted-no-tree", writeRawObject(bareA, "commit", "parent " &
      w.revA1 & "\n\nno tree\n"))
    crafted("absent-commit", repeat('6', 40))
    # Two spellings of one remote; an asserted identity the catalog does
    # not publish.
    var clash = w.standardImports()
    clash.add(ImportSpec(repo: "fed-catalog-a-again",
      remote: w.a.remote & ".git", gitRef: "main"))
    scenarios.add(("remote-clash", clash))
    var asserted = w.standardImports()
    asserted[1].interfaceArtifact = repeat('9', 64)
    scenarios.add(("asserted-identity", asserted))
    for (name, specs) in scenarios:
      let dir = consumer(name, specs)
      var tt = t
      for k, v in ctx(dir): tt[k] = v
      check expectText(name, refreshRefusal(dir), tt)
    # Refs: symbolic, a branch and a tag that disagree, a ref naming a blob.
    discard git(["--git-dir=" & bareA, "symbolic-ref", "refs/heads/follow",
      "refs/heads/main"])
    discard git(["--git-dir=" & bareA, "tag", "split", w.revA1])
    discard git(["--git-dir=" & bareA, "branch", "split",
      git(["--git-dir=" & bareA, "rev-parse", "nothing"]).strip()])
    discard git(["--git-dir=" & bareA, "tag", "blobtag", artifactBlob])
    for (name, gitRef) in [("ref-symbolic", "follow"), ("ref-both", "split"),
                           ("ref-blob", "blobtag")]:
      var specs = w.standardImports()
      specs[1].gitRef = gitRef
      let dir = consumer(name, specs)
      var tt = t
      for k, v in ctx(dir): tt[k] = v
      tt["revNothing"] = git(["--git-dir=" & bareA, "rev-parse",
        "nothing"]).strip()
      tt["blobA"] = artifactBlob
      check expectText(name, refreshRefusal(dir), tt)
    # The shared clone: no origin, two origins, another remote's origin, an
    # origin whose host depends on who parses it, an insteadOf redirect, a
    # SHA-256 store.
    let remote = w.a.remote
    let hostPath = remote["https://".len .. ^1]
    proc origins(values: seq[string]) =
      discard execCmdEx("git --git-dir=" & quoteShell(bareA) &
        " config --unset-all remote.origin.url")
      for v in values:
        discard git(["--git-dir=" & bareA, "config", "--add",
          "remote.origin.url", v])
    for (name, values) in [("store-no-origin", newSeq[string]()),
                           ("store-two-origins", @["https://example.invalid/x",
                             remote]),
                           ("store-other-origin", @[w.b.remote]),
                           ("store-ambiguous-origin",
                             @["https://evil.invalid?@" & hostPath])]:
      origins(values)
      let dir = consumer(name, w.standardImports())
      check expectText(name, refreshRefusal(dir), ctx(dir))
    origins(@[remote])
    discard git(["--git-dir=" & bareA, "config",
      "url.https://evil.invalid/.insteadOf", "https://example.invalid/"])
    block:
      let dir = consumer("store-insteadof", w.standardImports())
      check expectText("store-insteadof", refreshRefusal(dir), ctx(dir))
    discard git(["--git-dir=" & bareA, "config", "--remove-section",
      "url.https://evil.invalid/"])
    block:
      let shaRoot = top / "clones-sha256"
      let shaBare = sharedCloneOf(shaRoot, w.a.remote)
      createDir(shaBare)
      discard git(["init", "-q", "--bare", "--object-format=sha256", shaBare])
      discard git(["--git-dir=" & shaBare, "config", "remote.origin.url",
        w.a.remote])
      for repo in [w.packages, w.b]:
        discard repo.syncSharedClone(shaRoot)
      putEnv("REPRO_WORKSPACE_CLONES", shaRoot)
      try:
        let dir = consumer("store-sha256", w.standardImports())
        var tt = ctx(dir)
        tt["shaStore"] = shaBare
        check expectText("store-sha256", refreshRefusal(dir), tt)
      finally:
        putEnv("REPRO_WORKSPACE_CLONES", env.clonesRoot)
    # A damaged store: an object substituted under the artifact's id (git
    # serves it; discovery re-hashes and refuses).
    block:
      let looseRoot = top / "clones-loose"
      let looseBare = w.a.syncSharedClone(looseRoot, loose = true)
      let other = writeBlob(looseBare, "a different artifact")
      let blobFile = looseBare / "objects" / artifactBlob[0 .. 1] /
        artifactBlob[2 .. ^1]
      setFilePermissions(blobFile, {fpUserRead, fpUserWrite})
      copyFile(looseBare / "objects" / other[0 .. 1] / other[2 .. ^1],
        blobFile)
      for repo in [w.packages, w.b]:
        discard repo.syncSharedClone(looseRoot)
      putEnv("REPRO_WORKSPACE_CLONES", looseRoot)
      try:
        let dir = consumer("store-substituted", pinA(w.revA1))
        var tt = ctx(dir)
        tt["looseStore"] = looseBare
        tt["blobA"] = artifactBlob
        tt["otherBlob"] = gitObjectId("blob", "a different artifact")
        check expectText("store-substituted", refreshRefusal(dir), tt)
      finally:
        putEnv("REPRO_WORKSPACE_CLONES", env.clonesRoot)
    # Back to a clean store: re-selection succeeds again.
    let control = consumer("store-control", w.standardImports())
    check refresh(control) == 0

  test "an incumbent-pinned re-selection names no policy remedy for a contributor two catalogs offer":
    let dir = consumer("incumbent-same-contributor", w.standardImports())
    check refresh(dir) == 0
    var specs = w.standardImports()
    specs.add(ImportSpec(repo: "fed-catalog-a-mirror", remote: mirrorA.remote,
      commit: revMirrorA))
    writeDeclaration(dir, specs, @[(FedToolPackage, FedContributorA)])
    var t = ctx(dir)
    t["cfA1"] = parseLockedDependencies(readFile(dir / "repro.lock")).
      lockedProvisioningClaims()[0].contributionFingerprint
    check expectText("incumbent-same-contributor", refreshRefusal(dir), t)
    # Without a policy the incumbent's pin note still names the policy.
    writeDeclaration(dir, w.standardImports(), @[])
    check expectText("incumbent-ambiguous", refreshRefusal(dir), t)

  test "a contributor offered twice is never sent to the curator policy, and one catalog is not two":
    # Two catalogs offer contributor A and no policy is declared: naming A in
    # a policy cannot choose between them, so neither the composition nor the
    # re-selection note may say to (the incumbent lock pins A).
    let dir = consumer("same-contributor-no-policy", w.standardImports())
    check refresh(dir) == 0
    let specs = @[w.standardImports()[0], w.standardImports()[1], ImportSpec(
      repo: "fed-catalog-a-mirror", remote: mirrorA.remote,
      commit: revMirrorA)]
    writeDeclaration(dir, specs, @[])
    check expectText("same-contributor-no-policy", refreshRefusal(dir),
      ctx(dir))
    # One catalog publishing contributor A twice, and declaring the canonical
    # interface twice, differently (in-process: the production publisher
    # writes one record per declaration, but nothing stops a provider from
    # declaring two). The remedy names that ONE catalog and its publisher --
    # removing an [[import]] cannot resolve it.
    writeDeclaration(dir, w.standardImports(), @[])
    let answer = catalogsForReselect(dir, @[])
    var imports = answer.imports
    for i in imports.mitems:
      if i.coordinate.workspace == FedRepoA:
        var content = i.content.get()
        var second = content.contributions[0]
        second.tarballProvisioning[0].url = "https://example.invalid/second.tar.gz"
        second.location.line = 9
        content.contributions.add(second)
        i.content = some(content)
      if i.coordinate.workspace == FedRepoPackages:
        var content = i.content.get()
        var other = content.canonicalInterfaces[0]
        other.interfaceFingerprint = fp2
        other.location.line = 12
        content.canonicalInterfaces.add(other)
        i.content = some(content)
    let remedy = CatalogRemedyContext(projectRoot: dir,
      lockPath: dir / "repro.lock",
      reselectCommand: provisioningReselectCommand(dir, dir / "repro.lock"),
      declaration: answer.declaration)
    let t = ctx(dir)
    let twice = composeCatalogs(imports, CatalogSelectionPolicy(selections:
      @[CatalogSelectionRule(targetPackage: FedToolPackage,
        contributor: FedContributorA)]))
    let amb = twice.diagnostics.filterIt(it.kind == cdAmbiguousContribution)
    check amb.len == 0   # the duplicate owner makes the package ineligible
    let dup = twice.diagnostics.filterIt(
      it.kind == cdDuplicateCanonicalInterface)
    check dup.len == 1
    check remedyLines(dup[0], remedy, twice.diagnostics)[^1] == fill(
      "fix: catalog \"fed-packages\" ({decl}:3) declares the canonical " &
      "interface of \"federatedTool\" 2 times, differently (at repro.nim:3, " &
      "repro.nim:12); pin it at a revision that declares it once (the " &
      "`commit` or `ref` of its [[import]] in {decl}), or have its publisher " &
      "republish it; then re-select with `repro lock refresh --provisioning " &
      "{dir}`", t)
    # Without the duplicate owner, the twice-published contributor.
    for i in imports.mitems:
      if i.coordinate.workspace == FedRepoPackages:
        var content = i.content.get()
        content.canonicalInterfaces.setLen(1)
        i.content = some(content)
    for policy in [CatalogSelectionPolicy(selections: @[CatalogSelectionRule(
                     targetPackage: FedToolPackage,
                     contributor: FedContributorA)]),
                   CatalogSelectionPolicy()]:
      let onlyA = imports.filterIt(it.coordinate.workspace != FedRepoB)
      let c = composeCatalogs(onlyA, policy)
      let d = c.diagnostics.filterIt(it.kind == cdAmbiguousContribution)
      check d.len == 1
      check d[0].message.endsWith(". A catalog publishes one contribution " &
        "per contributor and package: pin a revision of that catalog that " &
        "does, or have it republished.")
      check "the catalogs that offer it" notin d[0].message
      check "Pin one with an explicit selection" notin d[0].message
      check (if policy.selections.len > 0: "which the curator policy " &
               "selects, all published by one catalog; a policy names a " &
               "contributor, not one of its contributions"
             else: "all from contributor \"" & FedContributorA & "\"; a " &
               "curator policy names a contributor, not one of its " &
               "contributions") in d[0].message
      check remedyLines(d[0], remedy, c.diagnostics)[^1] == fill(
        "fix: catalog \"fed-catalog-a\" ({decl}:8) publishes 2 " &
        "contributions from contributor \"github:example/fed-catalog-a\" " &
        "for \"federatedTool\" (declared at repro.nim:6, repro.nim:9). A " &
        "curator policy names a contributor, not one of its contributions, " &
        "so none can choose between them: pin \"fed-catalog-a\" at a " &
        "revision that publishes one (the `commit` or `ref` of its " &
        "[[import]] in {decl}), or have its publisher republish it with " &
        "one; then re-select with `repro lock refresh --provisioning {dir}`",
        t)

  test "structured diagnostic facts do not depend on import order":
    let dir = consumer("structured", w.standardImports(), policy = @[])
    var specs = w.standardImports()
    specs.add(ImportSpec(repo: "fed-catalog-a-mirror", remote: mirrorA.remote,
      commit: revMirrorA))
    writeDeclaration(dir, specs, @[])
    let answer = catalogsForReselect(dir, @[])
    let forward = composeCatalogs(answer.imports, answer.policy)
    var backward = answer.imports
    backward.reverse()
    let reversed = composeCatalogs(backward, answer.policy)
    check forward.refused
    check forward.diagnostics == reversed.diagnostics
    let amb = forward.diagnostics.filterIt(it.kind == cdAmbiguousContribution)
    check amb.len == 1
    check amb[0].eligible == @[FedContributorA, FedContributorB]
    # Parties are ordered by (contributor, coordinate key): "fed-catalog-a-
    # mirror|..." sorts before "fed-catalog-a|..." ('-' < '|').
    check amb[0].parties.mapIt(it.coordinate.workspace) ==
      @["fed-catalog-a-mirror", "fed-catalog-a", "fed-catalog-b"]
    let unsat = composeCatalogs(backward, CatalogSelectionPolicy(selections:
      @[CatalogSelectionRule(targetPackage: FedToolPackage,
        contributor: "github:example/nobody")]))
    let u = unsat.diagnostics.filterIt(it.kind == cdPolicySelectionUnsatisfied)
    check u.len == 1
    check u[0].eligible == @[FedContributorA, FedContributorB]
    check u[0].parties.mapIt(it.coordinate.workspace) ==
      @["fed-catalog-a-mirror", "fed-catalog-a", "fed-catalog-b"]

  test "evidence failures are reported for the records whose cause they hide, and only those":
    let dir = consumer("evidence", w.standardImports())
    check refresh(dir) == 0
    let text = readFile(dir / "repro.lock")
    let t = ctx(dir)
    proc editRecords(edit: proc (line: string): string): string =
      for line in text.splitLines(keepEol = true):
        if line.startsWith(ProvisioningLockKey & " = "):
          result.add(edit(line))
        else:
          result.add(line)
    # Only the record's revision is edited to one no store has: the
    # catalog changed, the contribution did not -- nothing needs evidence,
    # so no failure is printed although one occurred.
    writeFile(dir / "repro.lock", editRecords(proc (l: string): string =
      l.replace(w.revA1, repeat('7', 40))))
    check expectText("record-revision-only", buildRefusal(dir, defs), t)
    # The record's revision AND its contribution fingerprint edited, and a
    # record for another platform pair whose catalog revision no store has
    # either: only the failure that hides THIS change's cause is printed.
    var tt = t
    tt["cfA1"] = base["cfA1"]
    writeFile(dir / "repro.lock", editRecords(proc (l: string): string =
      let inner = l.strip()[(ProvisioningLockKey & " = [").len .. ^2].
        replace(w.revA1, repeat('7', 40)).replace(base["cfA1"],
          repeat('0', 64))
      let other = inner.replace(repeat('7', 40), repeat('8', 40)).replace(
        "host_platform = \"" & Host & "\"", "host_platform = \"arm64-linux\"").
        replace("target_platform = \"" & Host & "\"",
          "target_platform = \"arm64-linux\"")
      ProvisioningLockKey & " = [" & inner & ", " & other & "]\n"))
    check expectText("evidence-filtered", buildRefusal(dir, defs), tt)
    writeFile(dir / "repro.lock", text)

  test "catalog-level diagnostics name the import and the remedy":
    ## ``incomplete-catalog-coordinate``, ``missing-catalog`` and
    ## ``catalog-identity-conflict`` cannot come from the production
    ## catalog source (discovery completes every coordinate, raises
    ## instead of returning an unread catalog, and the declaration names a
    ## repo once); a source supplied in-process can produce them, and the
    ## build prints them like every other diagnostic.
    let dir = consumer("catalog-level", w.standardImports())
    check refresh(dir) == 0
    let production = productionProvisioningCatalogSource
    let real = production(ProvisioningCatalogRequest(projectRoot: dir,
      lockPath: dir / "repro.lock",
      catalogImportPins: parseLockedDependencies(readFile(dir /
        "repro.lock")).lockedCatalogImportPins(),
      lockClaims: parseLockedDependencies(readFile(dir /
        "repro.lock")).lockedProvisioningClaims()))
    var t = ctx(dir)
    for (name, mutate) in [
        ("incomplete-coordinate", proc (i: var seq[CatalogImport]) =
          i[2].coordinate.revision = ""),
        ("missing-catalog", proc (i: var seq[CatalogImport]) =
          i[2].content = none(CatalogContent)),
        ("identity-conflict", proc (i: var seq[CatalogImport]) =
          var twin = i[2]
          twin.content = some(CatalogContent())
          twin.discoveredAt = "elsewhere"
          i.add(twin))]:
      var imports = real.imports
      mutate(imports)
      let inputs = ProvisioningCatalogInputs(imports: imports,
        offered: real.offered, policy: real.policy, resolver: real.resolver,
        previous: real.previous, catalogImportPins: real.catalogImportPins,
        declaration: real.declaration)
      setProvisioningCatalogSource(
        proc (request: ProvisioningCatalogRequest): ProvisioningCatalogInputs =
          inputs)
      try:
        check expectText(name, buildRefusal(dir, defs), t)
      finally:
        setProvisioningCatalogSource(productionProvisioningCatalogSource)
    check buildRefusal(dir, defs) == ""

  test "a lock re-pinned by hand to another revision is refused with what changed and why":
    let dir = consumer("repinned", w.standardImports())
    check refresh(dir) == 0
    let oldLock = top / "repinned-old.lock"
    copyFile(dir / "repro.lock", oldLock)
    # Catalog A gains a committed file: a new revision, the same artifacts,
    # a new provider identity.
    let upstreamA = w.a.upstream
    discard git(["checkout", "-q", "-f", "main"], upstreamA)
    writeFile(upstreamA / "NOTES.md", "a committed change\n")
    discard git(["add", "-A"], upstreamA)
    discard git(["commit", "-q", "-m", "notes"], upstreamA)
    let revA2 = git(["rev-parse", "HEAD"], upstreamA).strip()
    discard w.a.syncSharedClone(env.clonesRoot)
    var t = ctx(dir)
    t["revA2"] = revA2
    t["provA2"] = providerAt(w.a, revA2)
    t["cfA2"] = contributionFingerprint(ContributionIdentity(
      contribution: recordOfPublished(w.publishedA1),
      providerIdentity: t["provA2"]), noContributionResolver).hex
    t["oldLock"] = oldLock
    # A diff lists unreadable catalogs by revision: the two revisions of
    # this run in their sorted order.
    t["revFirst"] = min(w.revA1, revA2)
    t["revSecond"] = max(w.revA1, revA2)
    # Only the catalog pin is edited, by hand, to the new revision.
    let text = readFile(dir / "repro.lock")
    proc withPinLine(edit: proc (line: string): string): string =
      for line in text.splitLines(keepEol = true):
        if line.startsWith(CatalogImportsLockKey & " = "):
          result.add(edit(line))
        else:
          result.add(line)
    writeFile(dir / "repro.lock", withPinLine(proc (l: string): string =
      l.replace(w.revA1, revA2)))
    check expectText("repinned", buildRefusal(dir, defs), t)
    # And the record's own revision edited to one no store has: the cause
    # cannot be determined, and the refusal says why.
    var both = ""
    for line in readFile(dir / "repro.lock").splitLines(keepEol = true):
      if line.startsWith(ProvisioningLockKey & " = "):
        both.add(line.replace(w.revA1, repeat('7', 40)))
      else:
        both.add(line)
    writeFile(dir / "repro.lock", both)
    check expectText("repinned-unreadable", buildRefusal(dir, defs), t)
    # Explicit re-selection adopts the new revision; the diff explains why,
    # and says why it cannot once the catalog cannot be read.
    writeFile(dir / "repro.lock", text)
    check refresh(dir) == 0
    let diff = lockDiffReport(oldLock, dir / "repro.lock")
    check diff.rc == 1
    check expectText("diff", diff.text, t)
    let bare = sharedCloneOf(env.clonesRoot, w.a.remote)
    moveDir(bare, bare & ".aside")
    try:
      let blind = lockDiffReport(oldLock, dir / "repro.lock")
      check blind.rc == 1
      check expectText("diff-blind", blind.text, t)
    finally:
      moveDir(bare & ".aside", bare)

  env.leave()
  removeDir(top)
