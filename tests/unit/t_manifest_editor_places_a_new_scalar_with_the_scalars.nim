## A new scalar key goes with the other scalar keys of its table, never below
## an array that follows them.
##
## When BR7's migration added `profile = "codetracer-fork"` to the nine
## product-adapted fork fragments, the manifest editor appended it after the
## table's LAST key, which in those fragments is a multi-line `remotes`
## array. The result reads as if `profile` were a property of the array, and
## it departs from the order every renderer in the editor writes
## (`repoFragmentText`: identity, origin, profile and roles first, then the
## arrays). Workspace-Manifests.md's key-order rule ("Key order is not
## cosmetic here") makes the editor, not its callers, responsible for where a
## key lands.
##
## Cases, each on a real file read back through the strict reader:
##   1. PRIMARY — a v2 fragment ending in a multi-line `remotes` array:
##      `setKey("repo", "profile", …)` with no `after` key writes `profile`
##      directly below the last scalar (`mainline`), above the blank line and
##      the array, and nothing else changes;
##   2. a new ARRAY still goes after the table's last key;
##   3. a table that holds only arrays gets a new scalar first;
##   4. an explicit `after` key is still honoured over the scalar rule.
##
## Mutation-checked: dropping the scalar placement (anchoring a new scalar at
## the table's last key, the previous behaviour) fails case 1 on byte
## equality with the expected text.
##
## No mocks: real files, the real editor and reader.

import std/[os, tempfiles, unittest]

import repro_workspace_manifests

const forkFragment = """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "aiken"
path = "metacraft-aiken-fork"
url_prefix = "metacraft-labs"
mainline = "codetracer"

remotes = [
  { name = "upstream", url_prefix = "aiken-lang", url_suffix = "aiken" },
]
"""

const forkFragmentWithProfile = """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "aiken"
path = "metacraft-aiken-fork"
url_prefix = "metacraft-labs"
mainline = "codetracer"
profile = "codetracer-fork"

remotes = [
  { name = "upstream", url_prefix = "aiken-lang", url_suffix = "aiken" },
]
"""

proc edited(dir, name, text: string;
            edit: proc(doc: var ManifestDoc)): string =
  let path = dir / name
  writeFile(path, text)
  var doc = loadManifestDoc(path)
  edit(doc)
  doc.saveManifestDoc()
  readFile(path)

suite "manifest editor places a new scalar with the scalars":

  test "t_manifest_editor_places_a_new_scalar_with_the_scalars":
    let dir = createTempDir("repro-editor-scalar-order-", "")
    defer: removeDir(dir)

    # ---- 1 (PRIMARY) -------------------------------------------------------
    let withProfile = edited(dir, "aiken.toml", forkFragment,
      proc(doc: var ManifestDoc) =
        check doc.setKey("repo", "profile", tomlStr("codetracer-fork")))
    check withProfile == forkFragmentWithProfile
    discard readRepoFragment(dir / "aiken.toml")

    # ---- 2: a new array goes after the last key ---------------------------
    let withTags = edited(dir, "tags.toml", forkFragment,
      proc(doc: var ManifestDoc) =
        check doc.setKey("repo", "tags", tomlStrings(["fork"])))
    check withTags == forkFragment & "tags = [\"fork\"]\n"
    discard readRepoFragment(dir / "tags.toml")

    # ---- 3: only arrays so far -> the scalar goes first -------------------
    const onlyArrays = "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
      "[repo]\ntags = [\"a\"]\n"
    let first = edited(dir, "only-arrays.toml", onlyArrays,
      proc(doc: var ManifestDoc) =
        check doc.setKey("repo", "name", tomlStr("x")))
    check first == "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
      "[repo]\nname = \"x\"\ntags = [\"a\"]\n"

    # ---- 4: an explicit `after` wins --------------------------------------
    let afterName = edited(dir, "after.toml", forkFragment,
      proc(doc: var ManifestDoc) =
        check doc.setKey("repo", "profile", tomlStr("codetracer-fork"),
          after = ["name"]))
    check afterName == """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "aiken"
profile = "codetracer-fork"
path = "metacraft-aiken-fork"
url_prefix = "metacraft-labs"
mainline = "codetracer"

remotes = [
  { name = "upstream", url_prefix = "aiken-lang", url_suffix = "aiken" },
]
"""
