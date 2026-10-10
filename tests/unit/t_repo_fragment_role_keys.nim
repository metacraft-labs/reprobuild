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
##   than silently dropped.
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
    check f.repo.mainlineBranch == some("dev")
    check f.repo.branch.isNone
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
    check f.repo.mainlineBranch.isNone
    check f.repo.profile == some("spec")

  test "a v1 fragment carrying a v2-only key is refused naming file and key":
    let dir = createTempDir("repro-repo-roles-", "")
    defer: removeDir(dir)
    for (key, line) in [("mainline", "mainline = \"dev\""),
                        ("unstable", "unstable = \"agents\""),
                        ("staging", "staging = false"),
                        ("stable", "stable = \"stable\""),
                        ("production", "production = \"prod\""),
                        ("lts", "lts = \"lts\""),
                        ("profile", "profile = \"product\"")]:
      let path = fragmentAt(dir, "v1-" & key, "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"x\"\npath = \"x\"\nbranch = \"dev\"\n" & line & "\n")
      let e = refusal(path)
      check e.path == path
      check e.keyPath == "repo." & key
      check "reprobuild.workspace.repo.v2" in e.innerMessage
    # The header spelling of the custom-role table, which the typed decoder
    # would drop without a word.
    let headerPath = fragmentAt(dir, "v1-branch-roles", """schema = "reprobuild.workspace.repo.v1"

[repo]
name = "x"
path = "x"
branch = "dev"

[repo.branch-roles]
beta = "beta"
""")
    let e = refusal(headerPath)
    check e.path == headerPath
    check e.keyPath == "repo.branch-roles"

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
