## `reprobuild.workspace.repo.v2` role keys decode, and a fragment is in ONE
## schema (Workspace-Branch-Roles.md §3.1, §3.6).
##
## What is checked, each against a real file read by the real reader:
##
## * the five optional built-in roles decode as a branch name or as `false`
##   (the tier declared absent), and an omitted one as undeclared;
## * `profile` decodes;
## * custom roles decode from `[repo.branch-roles]` in BOTH spellings — the
##   header form, which the pinned typed decoder drops without a word, and
##   the inline-table form — including a `false` value;
## * a `repo.v1` fragment carrying any v2-only key, or a `repo.v2` fragment
##   carrying `branch`, is refused with an error naming the file and the key;
## * an illegal role value (`true`, a number, an empty name) and an illegal
##   custom role name (a built-in name, upper case) are refused naming the
##   key;
## * a `[repo.<sub-table>]` a v2 fragment does not define is refused rather
##   than silently dropped;
## * a boolean, number or other non-string written for a string key — at the
##   top of `[repo]`, in a string array, or in a `remotes` / `copyfile` /
##   `linkfile` entry — is refused naming the key, rather than read as text
##   (Workspace-Manifests.md §"`repos/<repo>.toml` — Repository Descriptor").
## * a value of the wrong TOML type for a key that is not a string — an
##   integer (`depth`), a boolean (`single_branch`), an array (`tags`,
##   `remotes`) or an array entry — is refused naming the key, the type it
##   takes and what was written, not "TOML parser raised with no message"
##   (Workspace-Manifests.md §"Validation").
##
## No mocks: real files in a temporary directory, the real reader.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

proc fragmentAt(dir, name, text: string): string =
  result = dir / (name & ".toml")
  writeFile(result, text)

proc refusal(path: string): WorkspaceManifestParseError =
  ## The diagnostic `readRepoFragment` raises for `path`; fails the test when
  ## it reads cleanly.
  try:
    discard readRepoFragment(path)
  except WorkspaceManifestParseError as e:
    return e[]
  checkpoint("expected a refusal for " & path)
  fail()

suite "repo.v2 role keys":

  test "the built-in roles, false, profile and both branch-roles spellings decode":
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    let header = fragmentAt(dir, "header", """schema = "reprobuild.workspace.repo.v2"

# A product repo: agents is its unstable tier, it has no staging branch.
[repo]
name = "codetracer"
path = "codetracer"
profile = "product"
mainline = "dev"
unstable = "agents"
staging = false
stable = "stable"
production = "prod"
lts = "lts-1"

[repo.branch-roles]
staging-partner = "partner"
beta = false
""")
    let f = readRepoFragment(header)
    check f.schema == schemaRepoFragmentV2
    check f.repo.mainline == some("dev")
    check f.repo.profile == some("product")
    check f.repo.unstable == roleBranch("agents")
    check f.repo.staging == roleAbsent()
    check f.repo.stable == roleBranch("stable")
    check f.repo.production == roleBranch("prod")
    check f.repo.lts == roleBranch("lts-1")
    check f.repo.`branch-roles`.entries ==
      @[("beta", roleAbsent()), ("staging-partner", roleBranch("partner"))]
    let decls = f.repo.roleDecls
    check decls.mainline == some("dev")
    check decls.custom.len == 2

    let inline = fragmentAt(dir, "inline", """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "x"
path = "x"
mainline = "latest"
branch-roles = { staging-partner = "partner", beta = false }
""")
    let g = readRepoFragment(inline)
    check g.repo.`branch-roles`.entries ==
      @[("beta", roleAbsent()), ("staging-partner", roleBranch("partner"))]
    # Undeclared roles stay undeclared, not "absent".
    check not g.repo.unstable.isDeclared
    check g.repo.profile.isNone

  test "a v2 fragment may omit mainline (a profile can supply it)":
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    let f = readRepoFragment(fragmentAt(dir, "p", """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "x"
path = "x"
profile = "spec"
"""))
    check f.repo.mainline.isNone
    check f.repo.profile == some("spec")

  test "a fragment in the retired repo.v1 schema is refused naming the remedy":
    # The schema whose one branch key was `branch` is retired: a fragment
    # declaring it is refused at its `schema` key — whatever else it says,
    # a plain mainline or a role key — and the diagnostic names the current
    # schema and the key to rename, so the operator knows what to change.
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    for (key, line) in [("branch-only", ""),
                        ("mainline", "mainline = \"dev\""),
                        ("unstable", "unstable = \"agents\""),
                        ("profile", "profile = \"product\"")]:
      let path = fragmentAt(dir, "v1-" & key,
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"x\"\npath = \"x\"\nbranch = \"dev\"\n" & line &
        "\n")
      let e = refusal(path)
      check e.path == path
      check e.keyPath == "schema"
      check e.observedSchema == "reprobuild.workspace.repo.v1"
      check e.expectedSchema == "reprobuild.workspace.repo.v2"
      check "reprobuild.workspace.repo.v2" in e.innerMessage
      check "`mainline`" in e.innerMessage
    # The header spelling of the custom-role table is read in the current
    # schema (the typed decoder would drop it without a word, so it is
    # decoded from the tree).
    let headerPath = fragmentAt(dir, "v2-branch-roles", """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "x"
path = "x"
mainline = "dev"

[repo.branch-roles]
beta = "beta"
""")
    check readRepoFragment(headerPath).repo.`branch-roles`.entries ==
      @[("beta", roleBranch("beta"))]

  test "a v2 fragment carrying branch is refused naming file and key":
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    let path = fragmentAt(dir, "v2-branch", """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "x"
path = "x"
branch = "dev"
""")
    let e = refusal(path)
    check e.path == path
    check e.keyPath == "repo.branch"
    check "mainline" in e.innerMessage

  test "illegal role values and custom role names are refused naming the key":
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    let base = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"x\"\npath = \"x\"\nmainline = \"dev\"\n"
    for (name, extra, keyPath) in [
        ("true", "unstable = true\n", "repo.unstable"),
        ("number", "stable = 3\n", "repo.stable"),
        ("empty", "lts = \"\"\n", "repo.lts"),
        ("custom-true", "\n[repo.branch-roles]\nbeta = true\n",
         "repo.branch-roles.beta"),
        ("builtin-name", "\n[repo.branch-roles]\nstable = \"s\"\n",
         "repo.branch-roles.stable"),
        ("upper-name", "\n[repo.branch-roles]\nBeta = \"b\"\n",
         "repo.branch-roles.Beta")]:
      let e = refusal(fragmentAt(dir, name, base & extra))
      check e.keyPath == keyPath

  test "an unknown [repo.<sub-table>] in a v2 fragment is refused":
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    let e = refusal(fragmentAt(dir, "unknown-sub", """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "x"
path = "x"
mainline = "dev"

[repo.branch-rolez]
beta = "beta"
"""))
    check e.keyPath == "repo.branch-rolez"

  test "a non-string value written for a string [repo] key is refused naming the key":
    # The typed decoder turns a TOML boolean or number into text when the field
    # it fills is a string, so without a check against the generic tree
    # `revision = false` loaded as the revision "false" and `profile = 7` as
    # the profile named "7". Every key below is a string (or holds strings)
    # in `RepoBody`; each wrong-typed value must be refused at its key.
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    let base = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "mainline = \"dev\"\n"
    let named = "name = \"x\"\npath = \"x\"\n"
    var n = 0
    for (extra, keyPath) in [
        (named & "revision = false\n", "repo.revision"),
        # Shaped like a short commit id: unquoted, it would pin a checkout.
        (named & "revision = 1234567\n", "repo.revision"),
        (named & "profile = false\n", "repo.profile"),
        (named & "profile = 7\n", "repo.profile"),
        (named & "url_suffix = 7\n", "repo.url_suffix"),
        (named & "url_prefix = true\n", "repo.url_prefix"),
        (named & "remote = 1.5\n", "repo.remote"),
        (named & "vcs = false\n", "repo.vcs"),
        (named & "stability = 2\n", "repo.stability"),
        (named & "participation = true\n", "repo.participation"),
        (named & "clone_filter = 0\n", "repo.clone_filter"),
        ("name = 7\npath = \"x\"\n", "repo.name"),
        ("name = \"x\"\npath = false\n", "repo.path"),
        (named & "tags = [\"a\", 3]\n", "repo.tags[1]"),
        (named & "depends = [true]\n", "repo.depends[0]"),
        (named & "remotes = [{ name = \"origin\", url_suffix = 7 }]\n",
         "repo.remotes[0].url_suffix"),
        (named & "copyfile = [{ src = 1, dest = \"d\" }]\n",
         "repo.copyfile[0].src"),
        (named & "linkfile = [{ src = \"s\", dest = false }]\n",
         "repo.linkfile[0].dest")]:
      inc n
      let file = fragmentAt(dir, "wrong-type-" & $n, base & extra)
      let e = refusal(file)
      checkpoint(extra)
      check e.path == file
      check e.keyPath == keyPath
      check "`" & keyPath & "` must be a string, not " in e.msg

  test "a wrong-typed value for a non-string [repo] key is refused naming the key":
    # The typed decoder refuses these itself, but it raised with an empty
    # message and no key, so the diagnostic read "TOML parser raised with no
    # message". Workspace-Manifests.md §"Validation": the refusal names the
    # key path, the type the key takes and what was written instead.
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    let base = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "mainline = \"dev\"\nname = \"x\"\npath = \"x\"\n"
    var n = 0
    for (extra, keyPath, wanted, written) in [
        ("depth = \"3\"\n", "repo.depth", "an integer", "a string"),
        ("depth = true\n", "repo.depth", "an integer", "`true`"),
        ("depth = 1.5\n", "repo.depth", "an integer", "a float"),
        ("single_branch = 1\n", "repo.single_branch", "a boolean",
         "an integer"),
        ("single_branch = \"yes\"\n", "repo.single_branch", "a boolean",
         "a string"),
        ("tags = \"a\"\n", "repo.tags", "an array", "a string"),
        ("depends = 3\n", "repo.depends", "an array", "an integer"),
        ("remotes = \"origin\"\n", "repo.remotes", "an array", "a string"),
        ("remotes = [\"origin\"]\n", "repo.remotes[0]", "a table",
         "a string"),
        ("copyfile = { src = \"s\", dest = \"d\" }\n", "repo.copyfile",
         "an array", "a table"),
        # The typed decoder turns an array, an inline table or a number
        # written for a STRING key into text, so such a value earlier in the
        # record is not why the decode failed and must not take the blame
        # from the key that is.
        ("remote = [\"o\"]\ndepth = \"3\"\n", "repo.depth", "an integer",
         "a string"),
        ("revision = { a = \"b\" }\ndepth = \"3\"\n", "repo.depth",
         "an integer", "a string"),
        ("remote = 7\nsingle_branch = 1\n", "repo.single_branch",
         "a boolean", "an integer")]:
      inc n
      let file = fragmentAt(dir, "wrong-kind-" & $n, base & extra)
      let e = refusal(file)
      checkpoint(extra & " -> " & e.keyPath & ": " & e.msg)
      check e.path == file
      check e.keyPath == keyPath
      check ("`" & keyPath & "` must be " & wanted & ", not " & written) in
        e.msg
      check "no message" notin e.msg
