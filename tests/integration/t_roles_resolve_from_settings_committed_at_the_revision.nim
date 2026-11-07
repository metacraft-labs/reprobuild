## Branch roles resolved at a git REVISION of the metadata repository use the
## settings file committed at THAT revision (Workspace-Branch-Roles.md §3).
##
## A repo's roles come from its fragment, the profile it names and the
## workspace default profile, and profiles and custom roles live in the shared
## settings file `repro-workspace.toml` at the root of the metadata
## repository. Resolving the metadata at a revision (`openGitRevisionSource`)
## must therefore read the profiles and custom roles from the same revision:
## reading them from the working tree would resolve a pinned revision's
## fragments against today's branch model, and a source with no working tree
## at all (a bare repository) would have no profiles to resolve against.
##
## Fixture: a real git repository `meta/` holding `url-prefixes/`, a
## `repo.v2` fragment `core` that names the profile `product`, a project
## naming `core`, and a `settings.v1` file declaring `product` (mainline
## `dev`, unstable `agents`) and the custom role `beta` (falls back to
## `stable`).
##
##   * Revision A: as above.
##   * Revision B: the settings file's custom roles fall back in a cycle.
##   * Working tree: the settings file declares `product`'s mainline as
##     `trunk` (uncommitted), so a read that consults the working tree
##     resolves something neither revision contains.
##
## Asserted:
##   1. PRIMARY — at A, `core` resolves from A's settings: mainline `dev`
##      (declared by the profile), unstable `agents`, and the custom role
##      `beta` through `stable` to the mainline;
##   2. the directory source (and the path entry point) resolves the working
##      tree's settings: mainline `trunk` — a positive control showing the
##      two sources really disagree;
##   3. at B the committed settings file is refused, naming its revision
##      display path (`<git dir>@<short commit>:repro-workspace.toml`) and the
##      key, while A still resolves.
##
## Mutation-checked by making `sourceRoleSettings` (resolver.nim) answer a
## git-revision source from the working tree instead of from the revision:
## leg 1 then fails on the mainline assertion (`trunk`, not `dev`).
##
## No mocks: a real git repository in a temporary directory, read through the
## real readers and resolvers. Skip rule: `git` missing from PATH.

import std/[options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_workspace_manifests

proc git(dir: string; args: varargs[string]): string =
  ## Run git in `dir` with a fixed identity; any failure fails the fixture.
  var cmd = "git -C " & quoteShell(dir) &
    " -c user.name=fixture -c user.email=fixture@example.invalid" &
    " -c commit.gpgsign=false -c init.defaultBranch=main"
  for a in args:
    cmd.add(" " & quoteShell(a))
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(OSError, cmd & " failed: " & output)
  output.strip()

proc writeManifest(root, relPath, body: string) =
  let abs = root / relPath
  createDir(abs.parentDir)
  writeFile(abs, body)

proc settings(productMainline, customRoles: string): string =
  "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[profiles.product]\nmainline = \"" & productMainline & "\"\n" &
    "unstable = \"agents\"\n\n" & customRoles

const
  betaRole = "[branch-roles.beta]\nfallback = \"stable\"\n"
  cyclicRoles = "[branch-roles.alpha]\nfallback = \"omega\"\n\n" &
    "[branch-roles.omega]\nfallback = \"alpha\"\n"

proc coreOf(project: ResolvedProject): ResolvedRepo =
  for r in project.repos:
    if r.name == "core":
      return r
  raise newException(KeyError, "no resolved repo 'core'")

proc roleOf(repo: ResolvedRepo; name: string): ResolvedRole =
  let found = findRole(repo.roles, name)
  if found.isNone:
    raise newException(KeyError, "core resolved no role '" & name & "'")
  found.get()

suite "roles_resolve_from_settings_committed_at_the_revision":

  test "roles_resolve_from_settings_committed_at_the_revision":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real metadata repository")
    else:
      # Discovery must find the fixture's own settings file, not an inherited
      # explicit one.
      delEnv("REPRO_WORKSPACE_CONFIG")
      let scratch = createTempDir("repro-roles-at-revision-", "")
      defer: removeDir(scratch)
      let meta = scratch / "meta"
      createDir(meta)
      discard git(meta, "init", "-q")
      writeManifest(meta, "url-prefixes/acme.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n[url-prefix]\n" &
        "name = \"acme\"\nurl = \"https://git.example.invalid/acme\"\n")
      writeManifest(meta, "repos/core.toml",
        "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
        "name = \"core\"\npath = \"core\"\nurl_prefix = \"acme\"\n" &
        "profile = \"product\"\n")
      writeManifest(meta, "projects/demo.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "member_repos = [\"core\"]\n\n[project]\nname = \"demo\"\n")
      writeManifest(meta, "repro-workspace.toml", settings("dev", betaRole))
      discard git(meta, "add", "-A")
      discard git(meta, "commit", "-q", "-m", "A")
      let revA = git(meta, "rev-parse", "HEAD")
      writeManifest(meta, "repro-workspace.toml", settings("dev", cyclicRoles))
      discard git(meta, "commit", "-q", "-am", "B")
      let revB = git(meta, "rev-parse", "HEAD")
      # The working tree disagrees with both revisions.
      writeManifest(meta, "repro-workspace.toml", settings("trunk", betaRole))

      # 1. PRIMARY: at A, the roles come from A's settings file.
      let atA = openGitRevisionSource(meta, revA)
      defer: atA.close()
      let coreA = resolveProjectAt(atA, "projects/demo.toml").coreOf()
      check coreA.profile == "product"
      check coreA.roleOf("mainline").branch == "dev"
      check coreA.roleOf("mainline").declaredBy == rdkProfile
      check coreA.branch == "dev"
      check coreA.roleOf("unstable").branch == "agents"
      check coreA.roleOf("beta").branch == "dev"
      check coreA.roleOf("beta").fallbackPath == @["beta", "stable", "mainline"]

      # 2. Positive control: the working tree resolves its own settings.
      let byDir = resolveProjectAt(newDirectorySource(meta),
        "projects/demo.toml").coreOf()
      check byDir.roleOf("mainline").branch == "trunk"
      check resolveProject(meta / "projects" / "demo.toml").coreOf().branch ==
        "trunk"

      # 3. At B the committed settings file is refused, naming the revision.
      let atB = openGitRevisionSource(meta, revB)
      defer: atB.close()
      var refusal: ref WorkspaceManifestParseError
      try:
        discard resolveProjectAt(atB, "projects/demo.toml")
      except WorkspaceManifestParseError as err:
        refusal = err
      check not refusal.isNil
      if not refusal.isNil:
        checkpoint(refusal.msg)
        check refusal.path == atB.displayPath("repro-workspace.toml")
        check refusal.path.endsWith("@" & revB[0 ..< 12] &
          ":repro-workspace.toml")
        check refusal.keyPath == "branch-roles.alpha.fallback"
      # A is unaffected by B.
      check resolveProjectAt(atA, "projects/demo.toml").coreOf().branch == "dev"
