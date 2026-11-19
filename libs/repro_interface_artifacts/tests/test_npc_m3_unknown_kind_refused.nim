## NPC-M3 verification ``test_npc_m3_unknown_kind_refused`` (threat model
## G21): an ``[[import]]`` with an unknown ``kind`` is refused and names the
## line.
##
## ``kind`` names what a catalog publishes and what its identity means
## (Federated-Catalog-Imports.md § Catalog kinds). Read as the default, an
## index import with a mistyped kind would be looked for as a provisioning
## catalog, so the reader refuses every value it does not know -- including
## the known names in another letter case -- and points at the line to edit.
## Also covered: the ``catalog_imports`` lock record carries the kind
## (a ``v2`` record) without changing a ``provisioning`` record's bytes.

import std/[strutils, unittest]

import repro_lock/catalog_imports
import repro_interface_artifacts/catalog_declaration

const
  Path = "project/repro-catalogs.toml"
  Remote = "https://example.invalid/nim/packages-index"
  Commit = "0123456789abcdef0123456789abcdef01234567"
  Identity = "89abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567"

proc declaration(kindLine: string): string =
  ## A declaration whose second import's ``kind`` line is line 13.
  "schema = \"reprobuild.catalog-imports.v1\"\n" & # 1
    "\n" &                                          # 2
    "[[import]]\n" &                                # 3
    "repo = \"reprobuild-packages\"\n" &            # 4
    "remote = \"https://example.invalid/rp\"\n" &   # 5
    "ref = \"dev\"\n" &                             # 6
    "\n" &                                          # 7
    "[[import]]\n" &                                # 8
    "repo = \"nimble-index\"\n" &                   # 9
    "remote = \"" & Remote & "\"\n" &               # 10
    "commit = \"" & Commit & "\"\n" &               # 11
    "# the kind\n" &                                # 12
    kindLine & "\n"                                 # 13

proc refusalOf(text: string): string =
  try:
    discard parseCatalogImportsDeclaration(text, Path)
    "no refusal"
  except CatalogDeclarationError as e:
    e.msg

suite "NPC-M3: an [[import]] with an unknown kind is refused and names the line":

  test "an unknown kind is refused, naming the file, the line and the value":
    let msg = refusalOf(declaration("kind = \"nimble-indx\""))
    check Path & ":13: unknown kind \"nimble-indx\"" in msg
    check "nimble-index" in msg # the known kinds are named
    check "provisioning" in msg

  test "known names in another spelling and an empty kind are refused too":
    for value in ["Nimble-Index", "PROVISIONING", "nimble_index", "",
                  " nimble-index", "nimble-index "]:
      let msg = refusalOf(declaration("kind = \"" & value & "\""))
      check Path & ":13: unknown kind" in msg

  test "the known kinds are read, and the default is provisioning":
    let index = parseCatalogImportsDeclaration(
      declaration("kind = \"nimble-index\""), Path)
    check index.imports.len == 2
    check index.imports[0].repo == "nimble-index"
    check index.imports[0].kind == cikNimbleIndex
    check index.imports[1].repo == "reprobuild-packages"
    check index.imports[1].kind == cikProvisioning
    let explicit = parseCatalogImportsDeclaration(
      declaration("kind = \"provisioning\""), Path)
    check explicit.imports[0].kind == cikProvisioning
    let omitted = parseCatalogImportsDeclaration(declaration(""), Path)
    check omitted.imports[0].kind == cikProvisioning

  test "a duplicated kind is refused as a duplicated key":
    let msg = refusalOf(declaration("kind = \"nimble-index\"\nkind = \"nimble-index\""))
    check "duplicate key \"kind\"" in msg

  test "the lock record of a nimble-index import carries its kind; a provisioning record keeps its bytes":
    let provisioning = LockedCatalogImport(repo: "rp", remote: Remote & "-rp",
      gitRef: "dev", revision: Commit, interfaceArtifact: Identity)
    let index = LockedCatalogImport(repo: "nimble-index", remote: Remote,
      revision: Commit, interfaceArtifact: Identity, kind: cikNimbleIndex)
    # The provisioning record is the v1 record, byte for byte as before.
    check canonicalCatalogImportEntry(provisioning) ==
      "{ record = \"reprobuild.locked-catalog-import.v1\", repo = \"rp\", " &
      "remote = \"" & Remote & "-rp\", ref = \"dev\", revision = \"" & Commit &
      "\", interface_artifact = \"" & Identity & "\" }"
    check canonicalCatalogImportEntry(index) ==
      "{ record = \"reprobuild.locked-catalog-import.v2\", repo = " &
      "\"nimble-index\", remote = \"" & Remote & "\", kind = " &
      "\"nimble-index\", ref = \"\", revision = \"" & Commit &
      "\", interface_artifact = \"" & Identity & "\" }"
    let text = serializeCatalogImports(@[provisioning, index])
    check parseCatalogImports(text) == @[index, provisioning]

  test "a lock record with an unknown kind, or a v2 record naming provisioning, is refused":
    let index = LockedCatalogImport(repo: "nimble-index", remote: Remote,
      revision: Commit, interfaceArtifact: Identity, kind: cikNimbleIndex)
    let good = serializeCatalogImports(@[index])
    for bad in [good.replace("kind = \"nimble-index\"", "kind = \"nimble-indx\""),
                good.replace("kind = \"nimble-index\"", "kind = \"provisioning\""),
                good.replace(", kind = \"nimble-index\"", ""),
                good.replace("locked-catalog-import.v2", "locked-catalog-import.v1")]:
      var refused = false
      try:
        discard parseCatalogImports(bad)
      except LockedCatalogImportError:
        refused = true
      check refused
