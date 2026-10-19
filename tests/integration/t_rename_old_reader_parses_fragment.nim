## Declared-Repository-Renames.md §2.2 and §2.3 — the manifest plane.
##
## §2.2 is the claim the whole design hangs on: a fragment carrying
## `[extensions] previously` is parsed WITHOUT ERROR by the reader path that
## does not understand the key, and resolves to the same repo it resolves to
## today. It is the one assertion in that document an implementer cannot check
## by reading the code they just wrote, because what it is about is the
## behaviour of a reader that predates the key.
##
## It is checkable all the same, and checked exactly, by exercising the
## property that makes it true rather than an old binary: `decodeStrict`
## decodes every record with `TomlUnknownFields` deliberately UNSET, so an
## unknown key under `[repo]` raises, while `Extensions.readValue` walks the
## `[extensions]` table with `parseTable` and lets every sub-key pass through
## irrespective of name. The test asserts BOTH halves — the `[repo]` placement
## really does fail, and the `[extensions]` placement really does not — because
## the design decision is the CONTRAST between them, and a test that only
## showed `[extensions]` parsing would not distinguish a strict reader from a
## permissive one.
##
## §2.3's five validator rules are asserted here too: they are authoring errors
## that are cheap to make and expensive to notice later, and they are the only
## thing standing between a stale prior claim and `sync` moving a directory
## that belongs to another repo.
##
## No mocks: real manifest files on disk through the real readers.

import std/[os, strutils, tempfiles, unittest]
import repro_workspace_manifests

const prefixToml = """
schema = "reprobuild.workspace.url-prefix.v1"

[url-prefix]
name = "local"
url = "https://git.example.invalid/org"
"""

proc newManifestRoot(slug: string): string =
  result = createTempDir("repro-rename-manifest-" & slug & "-", "")
  createDir(result / "repos")
  createDir(result / "repo-sets")
  createDir(result / "url-prefixes")
  writeFile(result / "url-prefixes" / "local.toml", prefixToml)

proc writeRepo(root, fragment, body: string) =
  writeFile(root / "repos" / (fragment & ".toml"), body)

proc writeSet(root, name: string; members: openArray[string]) =
  var quoted: seq[string]
  for m in members:
    quoted.add("\"" & m & "\"")
  writeFile(root / "repo-sets" / (name & ".toml"),
    "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
    "member_repos = [" & quoted.join(", ") & "]\n\n" &
    "[repo-set]\nname = \"" & name & "\"\n")

proc fragmentBody(name, path: string; previously = ""): string =
  result =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"" & name & "\"\npath = \"" & path & "\"\n" &
    "url_prefix = \"local\"\nbranch = \"latest\"\n"
  if previously.len > 0:
    result.add("\n[extensions]\npreviously = " & previously & "\n")

suite "declared rename — the manifest plane":

  test "t_rename_old_reader_parses_fragment":
    let root = newManifestRoot("oldreader")
    defer: removeDir(root)

    # The key under `[extensions]`: parses, and the repo resolves exactly as it
    # would without the key.
    writeRepo(root, "widget-pm", fragmentBody("widget-pm", "widget-pm",
      "[{ name = \"widget-specs\", path = \"widget-specs\" }]"))
    writeRepo(root, "plain", fragmentBody("plain", "plain"))
    writeSet(root, "everything", ["widget-pm", "plain"])

    let resolved = resolveRepoSet(root / "repo-sets" / "everything.toml")
    check resolved.repos.len == 2
    var withKey = resolved.repos[0]
    var without = resolved.repos[1]
    if withKey.name != "widget-pm":
      swap(withKey, without)
    check withKey.name == "widget-pm"
    check withKey.path == "widget-pm"
    check withKey.branch == "latest"
    check withKey.fetchUrl == "https://git.example.invalid/org/widget-pm"
    # Every load-bearing field matches the shape a fragment WITHOUT the key
    # resolves to, which is what "resolves to the same repo it resolves to
    # today" means in practice.
    check withKey.vcs == without.vcs
    check withKey.stability == without.stability
    check withKey.projectRemote == without.projectRemote

    # The prior identity resolved, and its URL was DERIVED from the prior name
    # rather than declared. That derivation is what the identity check in §3.3
    # reads, and it is the reason the schema is one tuple array rather than two
    # parallel lists.
    check withKey.previously.len == 1
    check withKey.previously[0].name == "widget-specs"
    check withKey.previously[0].path == "widget-specs"
    check withKey.previously[0].fetchUrl ==
      "https://git.example.invalid/org/widget-specs"
    check without.previously.len == 0

  test "t_rename_previously_under_repo_is_rejected":
    ## THE CONTRAST that makes §2.2's placement decision real. Under `[repo]`
    ## the same key is an unknown field, `decodeStrict` raises, and the repo —
    ## plus whatever resolve needed it — fails. That is a strictly worse
    ## outcome than the orphan: the orphan at least still contains the work,
    ## and a tool that cannot read its manifests can neither diagnose nor
    ## repair anything.
    let root = newManifestRoot("underrepo")
    defer: removeDir(root)

    writeRepo(root, "widget-pm",
      "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"widget-pm\"\npath = \"widget-pm\"\n" &
      "url_prefix = \"local\"\nbranch = \"latest\"\n" &
      "previously = [{ name = \"widget-specs\" }]\n")
    writeSet(root, "everything", ["widget-pm"])

    expect WorkspaceManifestParseError:
      discard resolveRepoSet(root / "repo-sets" / "everything.toml")

  test "t_rename_validator_rejects_an_entry_restating_the_present_identity":
    ## §2.3 rule 1. An entry that restates `[repo]` makes the CURRENT path a
    ## "prior" path, which makes the relocation check consider the live
    ## checkout a candidate for moving onto itself.
    let root = newManifestRoot("restates")
    defer: removeDir(root)

    writeRepo(root, "widget-pm", fragmentBody("widget-pm", "widget-pm",
      "[{ name = \"widget-pm\", path = \"widget-pm\" }]"))
    writeSet(root, "everything", ["widget-pm"])

    expect WorkspaceManifestParseError:
      discard resolveRepoSet(root / "repo-sets" / "everything.toml")

  test "t_rename_validator_rejects_a_prior_path_claimed_by_a_live_repo":
    ## §2.3 rule 2 — THE DANGEROUS ONE. A forge frees the old name when a
    ## repository is renamed and lets anyone create a new repository there; if
    ## a fragment then legitimately declares that path, a stale prior claim
    ## from another fragment would authorise moving a directory that belongs to
    ## someone else. A live claim always wins and the prior claim is an error,
    ## not a silent loss.
    let root = newManifestRoot("liveclaim")
    defer: removeDir(root)

    writeRepo(root, "widget-pm", fragmentBody("widget-pm", "widget-pm",
      "[{ name = \"widget-specs\", path = \"widget-specs\" }]"))
    writeRepo(root, "widget-specs",
      fragmentBody("widget-specs", "widget-specs"))
    writeSet(root, "everything", ["widget-pm", "widget-specs"])

    expect WorkspaceManifestParseError:
      discard resolveRepoSet(root / "repo-sets" / "everything.toml")

  test "t_rename_validator_rejects_two_fragments_claiming_one_ancestor":
    ## §2.3 rule 4. Two repos claiming one ancestor cannot both be right, and
    ## whichever `sync` reached first would win by accident.
    let root = newManifestRoot("twoclaims")
    defer: removeDir(root)

    writeRepo(root, "widget-pm", fragmentBody("widget-pm", "widget-pm",
      "[{ name = \"widget-specs\", path = \"widget-specs\" }]"))
    writeRepo(root, "gadget-pm", fragmentBody("gadget-pm", "gadget-pm",
      "[{ name = \"widget-specs\", path = \"widget-specs\" }]"))
    writeSet(root, "everything", ["widget-pm", "gadget-pm"])

    expect WorkspaceManifestParseError:
      discard resolveRepoSet(root / "repo-sets" / "everything.toml")

  test "t_rename_validator_applies_the_live_path_rules_to_a_prior_path":
    ## §2.3 rule 5. A prior path places a directory MOVE on every machine that
    ## syncs, so it earns the same scrutiny the live `path` already gets —
    ## `declaredCheckoutPathRejection`, the same proc, rather than a second,
    ## laxer check.
    let root = newManifestRoot("pathrules")
    defer: removeDir(root)
    writeSet(root, "everything", ["widget-pm"])

    for bad in ["../outside", "/absolute/elsewhere", "./."]:
      writeRepo(root, "widget-pm", fragmentBody("widget-pm", "widget-pm",
        "[{ path = \"" & bad & "\" }]"))
      checkpoint("expected a rejection for previous path '" & bad & "'")
      expect WorkspaceManifestParseError:
        discard resolveRepoSet(root / "repo-sets" / "everything.toml")

  test "t_rename_validator_rejects_unknown_and_empty_previously_entries":
    ## Shape rules the strict decoder cannot reach inside `[extensions]` to
    ## enforce. A misspelled field would otherwise be a silently-ignored key,
    ## and a typo'd `path` makes the whole relocation not happen — which reads
    ## exactly like a tool that does not implement renames. `branch` is
    ## rejected BY NAME because it is the field a reader would most reasonably
    ## expect to be accepted, and §2 says it deliberately is not.
    let root = newManifestRoot("shaperules")
    defer: removeDir(root)
    writeSet(root, "everything", ["widget-pm"])

    for bad in ["[{ nmae = \"typo\" }]",
                "[{ branch = \"main\" }]",
                "[{ }]",
                "\"not-an-array-of-tables\"",
                "[{ path = 7 }]"]:
      writeRepo(root, "widget-pm",
        fragmentBody("widget-pm", "widget-pm", bad))
      checkpoint("expected a rejection for previously = " & bad)
      expect WorkspaceManifestParseError:
        discard resolveRepoSet(root / "repo-sets" / "everything.toml")

  test "t_rename_url_prefix_change_derives_the_prior_url":
    ## §2 — `url_prefix` / `url_suffix` exist for a repo that changed ORG or
    ## HOST, and the prior URL has to compose through the same two paths the
    ## live one does or the reconstruction is a guess. A guess here authorises
    ## moving a directory.
    let root = newManifestRoot("prefixchange")
    defer: removeDir(root)
    writeFile(root / "url-prefixes" / "oldorg.toml",
      "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
      "[url-prefix]\nname = \"oldorg\"\n" &
      "url = \"https://git.example.invalid/previous-org\"\n")
    writeRepo(root, "widget-pm", fragmentBody("widget-pm", "widget-pm",
      "[{ url_prefix = \"oldorg\" }]"))
    writeSet(root, "everything", ["widget-pm"])

    let resolved = resolveRepoSet(root / "repo-sets" / "everything.toml")
    check resolved.repos.len == 1
    let repo = resolved.repos[0]
    check repo.fetchUrl == "https://git.example.invalid/org/widget-pm"
    check repo.previously.len == 1
    # Name and path are UNCHANGED (omitted means "unchanged from `[repo]`"),
    # and only the URL moved — the org-rename case.
    check repo.previously[0].name == "widget-pm"
    check repo.previously[0].path == "widget-pm"
    check repo.previously[0].fetchUrl ==
      "https://git.example.invalid/previous-org/widget-pm"

  test "t_rename_two_hops_keep_name_and_path_paired":
    ## §2.1 — a repo can move twice (`foo` -> `vendor/foo` -> `vendor/bar`).
    ## Two flat lists would record four strings and no way to know that
    ## `vendor/foo` was never called `foo`. Declaration order is "most recent
    ## first", and first-match-wins in `sync` is its only observable effect.
    let root = newManifestRoot("twohops")
    defer: removeDir(root)

    writeRepo(root, "bar", fragmentBody("bar", "vendor/bar",
      "[{ name = \"foo\", path = \"vendor/foo\" }, " &
      "{ name = \"foo\", path = \"foo\" }]"))
    writeSet(root, "everything", ["bar"])

    let resolved = resolveRepoSet(root / "repo-sets" / "everything.toml")
    check resolved.repos.len == 1
    let repo = resolved.repos[0]
    check repo.previously.len == 2
    check repo.previously[0].path == "vendor/foo"
    check repo.previously[0].name == "foo"
    check repo.previously[1].path == "foo"
    check repo.previously[1].name == "foo"
    # Both hops derive the same prior URL, because the server-side name never
    # changed — which is the pairing a flat-list schema could not express.
    check repo.previously[0].fetchUrl ==
      "https://git.example.invalid/org/foo"
    check repo.previously[1].fetchUrl ==
      "https://git.example.invalid/org/foo"
