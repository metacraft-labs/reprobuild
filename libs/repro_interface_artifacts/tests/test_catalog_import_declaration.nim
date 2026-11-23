## The pure half of federated catalog discovery -- ReproOS-Campaign-
## Completion M6 deliverables 1 and 2 (``reprobuild-specs/
## Federated-Catalog-Imports.md`` § The declaration, § What a catalog
## publishes, § Resolver inputs).
##
## ``repro_interface_artifacts/catalog_declaration``:
##
##   * ``parseCatalogImportsDeclaration`` reads ``repro-catalogs.toml``: it
##     accepts the declared subset, is independent of table order, and
##     refuses -- collecting every cause -- each construct outside it: an
##     unknown or duplicated key, a key outside a table, another table, an
##     inline table, an array, a literal or multi-line string, an unknown
##     escape, a byte-order mark, a missing or foreign schema, an import
##     naming both or neither of ``commit`` / ``ref``, a branch name or an
##     abbreviated id where a commit is required, a full-width id as a
##     ``ref``, a ref git would refuse, a local path / ``file:`` URL / drive
##     letter as a remote, a remote whose host depends on who parses it,
##     one repo or one remote imported twice, an incomplete policy rule, a
##     comment holding a control character, and text that is not UTF-8;
##   * ``publishedCatalogContent`` classifies published artifacts by content
##     (no contributions: a canonical interface; contributions: a
##     contribution set) and refuses imported, developInterface and unpinned
##     records and an empty publication;
##   * ``decodePublishedArtifact`` refuses bytes that are not an artifact
##     and an artifact whose stored fingerprint is not the semantic one;
##   * ``catalogProviderIdentity`` is a 64-hex function of the object format
##     and the root tree, and nothing else;
##   * ``offeredContributionResolver`` binds a dependency only to a UNIQUE
##     offered identity.
##
## Test-double policy: NO mocks, doubles or fakes. Artifacts are produced by
## the production projection (``toProjectInterface`` / ``artifactFor``) and
## encoded / decoded by the production codec.

import std/[algorithm, options, sequtils, strutils, unittest]

import repro_hash
import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/catalog_declaration
import repro_interface_artifacts/contribution_fingerprint

const
  Rev = "0123456789abcdef0123456789abcdef01234567"
  Art = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

proc decl(body: string): string =
  "schema = \"reprobuild.catalog-imports.v1\"\n" & body

proc parse(text: string): CatalogImportsDeclaration =
  parseCatalogImportsDeclaration(text, "repro-catalogs.toml")

proc semantic(d: CatalogImportsDeclaration): CatalogImportsDeclaration =
  ## ``d`` without its diagnostic line numbers, which name where a table
  ## starts and are no input of anything.
  result = d
  for i in 0 ..< result.imports.len:
    result.imports[i].line = 0

proc refusal(text: string): string =
  try:
    discard parse(text)
    ""
  except CatalogDeclarationError as err:
    err.msg

const Valid = """
# The catalogs this project imports.
[[import]]
repo = "catalog-b"
remote = "https://example.invalid/catalog-b"
ref = "main"   # moving; the lock pins it

[[import]]
repo = "catalog-a"
remote = "https://example.invalid/catalog-a"
commit = "0123456789ABCDEF0123456789abcdef01234567"
interface_artifact = "ABCDEF0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789"

[[policy]]
package = "tool"
contributor = "github:example/catalog-b"
"""

proc importBlock(fields: varargs[string]): string =
  result = "[[import]]\n"
  for f in fields:
    result.add(f & "\n")

proc artifactWith(contributions: seq[InterfaceProvisioningContribution];
                  name = "catalog"): ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(projectName: name, packageName: name,
    provisioningContributions: contributions))

proc contribution(contributor: string; iface = repeat('a', 64)):
    InterfaceProvisioningContribution =
  InterfaceProvisioningContribution(targetPackage: "tool",
    targetInterfaceFingerprint: iface, contributor: contributor,
    nixProvisioning: @[InterfaceNixProvisioning(packageName: "tool",
      contributor: contributor, selector: "nixpkgs#tool",
      executablePath: "bin/tool", nixpkgsRev: Rev,
      nixpkgsNarHash: "sha256-" & repeat('A', 43) & "=",
      lockIdentity: "nix:tool")])

proc bytesOf(a: ProjectInterfaceArtifact): string =
  for b in encodeProjectInterfaceArtifact(a):
    result.add(char(b))

suite "catalog import declarations and published catalog content":

  test "a valid declaration reads, sorted, with commits and artifacts lower-cased":
    let d = parse(decl(Valid))
    check d.imports.mapIt(it.repo) == @["catalog-a", "catalog-b"]
    check d.imports[0].commit == Rev
    check d.imports[0].gitRef == ""
    check d.imports[0].interfaceArtifact == Art
    check d.imports[1].gitRef == "main"
    check d.imports[1].commit == ""
    check d.policy.selections == @[CatalogSelectionRule(targetPackage: "tool",
      contributor: "github:example/catalog-b")]
    # CRLF line endings read the same.
    check parse(decl(Valid).replace("\n", "\r\n")) == d

  test "the order of tables is not an input":
    let a = importBlock("repo = \"x\"", "remote = \"https://h/x\"",
      "commit = \"" & Rev & "\"")
    let b = importBlock("remote = \"https://h/y\"", "ref = \"dev\"",
      "repo = \"y\"")
    let p1 = "[[policy]]\npackage = \"p\"\ncontributor = \"c1\"\n"
    let p2 = "[[policy]]\ncontributor = \"c2\"\npackage = \"q\"\n"
    let orders = @[a & b & p1 & p2, b & a & p2 & p1, p1 & b & p2 & a,
      p2 & a & p1 & b]
    let first = semantic(parse(decl(orders[0])))
    for o in orders:
      check semantic(parse(decl(o))) == first

  test "every construct outside the subset refuses, naming every cause":
    let good = importBlock("repo = \"x\"", "remote = \"https://h/x\"",
      "commit = \"" & Rev & "\"")
    check refusal(decl(good)) == ""
    let cases = @[
      ("\xEF\xBB\xBF" & decl(good), "byte-order mark"),
      (good, "missing `schema"),
      ("schema = \"reprobuild.catalog-imports.v2\"\n" & good, "unsupported schema"),
      (decl("color = \"red\"\n" & good), "unknown top-level key"),
      (decl(good & "color = \"red\"\n"), "unknown key \"color\""),
      (decl(good & "repo = \"z\"\n"), "duplicate key \"repo\""),
      (decl("[imports]\n" & good), "unsupported table header"),
      (decl("[[ import ]]\n" & good), "unsupported table header"),
      (decl(good & "tags = [\"a\"]\n"), "must be a basic"),
      (decl(good & "extra = { a = \"b\" }\n"), "must be a basic"),
      (decl(good.replace("\"https://h/x\"", "'https://h/x'")), "must be a basic"),
      (decl(good & "note = \"\"\"x\"\"\"\n"), "must be a basic"),
      (decl(good.replace("\"https://h/x\"", "\"https:\\u002f/h/x\"")), "an escape other than"),
      (decl(good.replace("\"https://h/x\"", "\"https://h/x")), "not terminated"),
      (decl(good.replace("\"https://h/x\"", "\"https://h/x\" trailing")), "unexpected text"),
      (decl(good.replace("repo = \"x\"", "lock.repo = \"x\"")), "expected `=`"),
      (decl(good.replace("repo = \"x\"", "\"repo\" = \"x\"")), "expected `key"),
      (decl(good.replace("commit = \"" & Rev & "\"", "ref = \"main\"\ncommit = \"" & Rev & "\"")), "exactly one of"),
      (decl(good.replace("commit = \"" & Rev & "\"", "")), "exactly one of"),
      (decl(good.replace(Rev, "main")), "is not a full-width commit id"),
      (decl(good.replace(Rev, Rev[0 ..< 12])), "is not a full-width commit id"),
      (decl(good.replace("commit = \"" & Rev & "\"", "ref = \"" & Rev & "\"")), "full-width object id"),
      (decl(good.replace("commit = \"" & Rev & "\"", "ref = \"main..dev\"")), "contains '..'"),
      (decl(good.replace("commit = \"" & Rev & "\"", "ref = \"main@{1}\"")), "contains '..', '@{'"),
      (decl(good.replace("commit = \"" & Rev & "\"", "ref = \"-main\"")), "starts with '-'"),
      (decl(good.replace("commit = \"" & Rev & "\"", "ref = \"ma in\"")), "does not allow"),
      (decl(good.replace("commit = \"" & Rev & "\"", "ref = \"HEAD~1\"")), "does not allow"),
      (decl(good.replace("\"https://h/x\"", "\"file:///srv/x\"")), "file: URL"),
      (decl(good.replace("\"https://h/x\"", "\"/srv/x\"")), "filesystem path"),
      (decl(good.replace("\"https://h/x\"", "\"../x\"")), "filesystem path"),
      (decl(good.replace("\"https://h/x\"", "\"C:/x\"")), "drive letter"),
      (decl(good.replace("repo = \"x\"", "repo = \" x\"")), "whitespace"),
      (decl(good.replace("repo = \"x\"", "")), "missing `repo`"),
      (decl(good & "interface_artifact = \"abc\"\n"), "not a 64-hex"),
      (decl(good & good.replace("\"https://h/x\"", "\"https://h/x2\"")), "imported twice"),
      (decl(good & good.replace("repo = \"x\"", "repo = \"x2\"")), "imported twice"),
      (decl(good & "[[policy]]\npackage = \"p\"\n"), "missing `contributor`"),
      (decl(good & "[[policy]]\ncontributor = \"c\"\n"), "missing `package`"),
      (decl(good & "[[policy]]\npackage = \"p\"\ncontributor = \"c\"\nrank = \"1\"\n"), "unknown key \"rank\""),
      (decl("schema = \"reprobuild.catalog-imports.v1\"\n" & good), "duplicate key \"schema\""),
      (decl(good.replace("commit = \"" & Rev & "\"", "ref = \"\"")), "ref \"\" of [[import]] \"x\" is empty"),
      (decl(good.replace("\"https://h/x\"", "\"https://h/\tx\"")), "contains a control character"),
      (decl(good & "[[policy]]\npackage = \" p\"\ncontributor = \"c\"\n"), "policy package \" p\" has leading"),
      (decl(good & "[[policy]]\npackage = \"p\"\ncontributor = \"/srv/c\"\n"), "policy contributor \"/srv/c\" is a filesystem path"),
      # Verification round (2026-10-03). A comment holding a control
      # character -- a lone CR, behind which an editor shows a line no TOML
      # reader sees -- whole-line or after a value; text that is not UTF-8;
      # and a remote whose host depends on who parses it (curl ends the
      # authority at '?' / '#', the identity check takes the host after the
      # first '@').
      (decl("# note\rinterface_artifact = \"" & Art & "\"\n" & good), "a comment contains a control character"),
      (decl(good.replace("repo = \"x\"", "repo = \"x\" # n\x01")), "the comment after the value of \"repo\" contains a control character"),
      (decl(good & "# \x7f\n"), "a comment contains a control character"),
      (decl(good & "# \xff\n"), "is not valid UTF-8"),
      (decl(good.replace("\"https://h/x\"", "\"https://evil?@h/x\"")), "make the host it names depend on who parses it"),
      (decl(good.replace("\"https://h/x\"", "\"https://evil#@h/x\"")), "make the host it names depend on who parses it"),
      (decl(good.replace("\"https://h/x\"", "\"https://a@b@h/x\"")), "more than one '@'"),
      (decl(good.replace("\"https://h/x\"", "\"h.test:o/x@y\"")), "nor an scp-like")]
    for (text, expected) in cases:
      let r = refusal(text)
      check expected in r
      if expected notin r:
        echo "    expected ", expected.escape(), " in ", r.escape()
    # Every cause is reported, not only the first.
    let two = refusal(decl(good.replace(Rev, "main").replace("\"https://h/x\"",
      "\"file:///x\"")))
    check "is not a full-width commit id" in two
    check "file: URL" in two

  test "published artifacts are classified by content and their records checked":
    let canonical = artifactFor(ProjectInterface(projectName: "tool",
      packageName: "tool"))
    let set = artifactWith(@[contribution("github:example/a")])
    var refusals: seq[string] = @[]
    let content = publishedCatalogContent(@[
      PublishedArtifact(path: "published-interfaces/tool.rbsz",
        artifact: canonical),
      PublishedArtifact(path: "published-interfaces/catalog.rbsz",
        artifact: set)], refusals)
    check refusals.len == 0
    check content.canonicalInterfaces == @[catalogInterface("tool",
      toHex(canonical.interfaceFingerprint.bytes).toLowerAscii())]
    check content.contributions == set.projectInterface.provisioningContributions
    # Refusals.
    var imported = contribution("github:example/a")
    imported.imported = true
    var develop = contribution("github:example/a")
    develop.developInterface = true
    develop.targetInterfaceFingerprint = ""
    for (bad, expected) in [(imported, "IMPORTED"), (develop, "developInterface"),
        (contribution("github:example/a", iface = "abc"), "not pinned")]:
      var r: seq[string] = @[]
      discard publishedCatalogContent(@[PublishedArtifact(path: "p",
        artifact: artifactWith(@[bad]))], r)
      check r.len == 1
      check r.len > 0 and expected in r[0]
    var empty: seq[string] = @[]
    discard publishedCatalogContent(@[], empty)
    check empty == @["the catalog publishes no interface artifacts"]

  test "a published artifact must decode with its semantic fingerprint":
    let a = artifactWith(@[contribution("github:example/a")])
    check decodePublishedArtifact("p", bytesOf(a)) == a
    var raised = ""
    try:
      discard decodePublishedArtifact("published-interfaces/x.rbsz", "garbage")
    except ValueError as err:
      raised = err.msg
    check "published-interfaces/x.rbsz is not a readable interface artifact" in raised
    # A stored fingerprint that is the legacy wire digest (accepted by the
    # envelope codec) is refused here: it is not the semantic one.
    var legacy = a
    let payload = encodeInterfacePayload(a.projectInterface)
    legacy.interfaceFingerprint = blake3DomainDigest(payload,
      hdMetadataEnvelope)
    check legacy.interfaceFingerprint != a.interfaceFingerprint
    # The envelope codec itself accepts it ...
    check decodeProjectInterfaceArtifact(encodeProjectInterfaceArtifact(
      legacy)).interfaceFingerprint == legacy.interfaceFingerprint
    # ... and the publication reader does not.
    raised = ""
    try:
      discard decodePublishedArtifact("p", bytesOf(legacy))
    except ValueError as err:
      raised = err.msg
    check "must be republished" in raised

  test "the provider identity is a function of the root tree alone":
    let t1 = repeat("ab", 20)
    let t2 = repeat("cd", 20)
    let a = catalogProviderIdentity("sha1", t1)
    check a.len == 64
    check a.allIt(it in {'0'..'9', 'a'..'f'})
    check catalogProviderIdentity("sha1", t1) == a
    check catalogProviderIdentity("sha1", t1.toUpperAscii()) == a
    check catalogProviderIdentity("sha1", t2) != a
    check catalogProviderIdentity("sha256", t1) != a
    let content = CatalogContent(contributions: @[contribution("c1"),
      contribution("c2")])
    let offered = offeredIdentities(content, a)
    check offered.len == 2
    check offered.allIt(it.providerIdentity == a and it.dependencies.len == 0 and
      it.fromSourceProvisioning.len == 0)

  test "the dependency resolver binds only a unique offered identity":
    let x = ContributionIdentity(contribution: contribution("c1"),
      providerIdentity: repeat('a', 64))
    var y = x
    y.providerIdentity = repeat('b', 64)
    let dep = ContributionDependencyRef(targetPackage: "tool",
      contributor: "c1", targetInterfaceFingerprint: repeat('A', 64))
    check offeredContributionResolver(@[x])(dep) == some(x)
    check offeredContributionResolver(@[x, y])(dep).isNone
    check offeredContributionResolver(@[])(dep).isNone
    var other = dep
    other.contributor = "c2"
    check offeredContributionResolver(@[x])(other).isNone
    var otherPackage = dep
    otherPackage.targetPackage = "other-tool"
    check offeredContributionResolver(@[x])(otherPackage).isNone
    var otherInterface = dep
    otherInterface.targetInterfaceFingerprint = repeat('b', 64)
    check offeredContributionResolver(@[x])(otherInterface).isNone
