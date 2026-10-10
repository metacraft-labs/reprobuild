## `repro-workspace.toml` (`reprobuild.workspace.settings.v1`) decodes in full.
##
## Workspace-Settings-Files.md §3 defines the shared settings file: the root
## repo's roles under `[workspace]` (Workspace-Branch-Roles.md §3.4),
## `[projects]`, `[records]`, `[[manifest]]` layers, `[profiles.<name>]`
## (with their own `branch-roles` sub-tables), `[branch-roles.<name>]`, and
## the unchanged `[verify]` / `[develop]` / `[locking]` / `[foreign_env]`.
##
## The file is decoded from the generic TOML tree rather than by the typed
## strict decoder (which drops dotted sub-table headers silently), so this test
## also pins down that the strict reader's rules still hold: an unknown key
## anywhere is refused naming its key path, a wrong value type is refused,
## and so are an unknown visibility tier, a layer with two sources, and a
## `local_path` under `.repro/`. A typed round trip through the editor's
## `workspaceSettingsText` checks the writer emits what the reader reads.
##
## No mocks: real files in a temporary directory, the real reader and writer.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const fullSettings = """schema = "reprobuild.workspace.settings.v1"

# The root repo's own roles.
[workspace]
profile = "product"
default_profile = "product"
mainline = "dev"
unstable = "agents"
staging = false

[workspace.branch-roles]
staging-partner = "partner"

[projects]
default = ["reprobuild", "codetracer"]
default_template = "metacraft-project"

[records]
url = "https://git.example.invalid/acme/records.git"
branch = "latest"
publish_locks = true

[[manifest]]
name = "internal"
url = "git@git.example.invalid:acme/internal-manifests"
branch = "latest"
visibility = "org"
revision = "v2026.06"

[[manifest]]
name = "partner"
visibility = "team"

[[manifest]]
local_path = "../shared-manifests"
visibility = "public"

[profiles.product]
mainline = "dev"
unstable = "agents"
stable = "stable"

[profiles.product.branch-roles]
staging-partner = "staging-partner"

[profiles.spec]
mainline = "latest"

[branch-roles.staging-partner]
fallback = "staging"

[branch-roles.beta]
fallback = "stable"

[verify]
require_signature = true
allowed_signers = "trust/signers"
allowed_keys = ["ssh-ed25519 AAAA bot"]
signer_identity = "bot@manifest"

[develop]
org_urls = ["https://git.example.invalid/acme/"]

[locking]
route = [
  { visibility = "team", backend = "git-checkout", path = ".repro/records", repos = ["a", "b"] },
]

[foreign_env]
auto_load_envrc = false
auto_load_flake = true
"""

proc settingsAt(dir, text: string): string =
  result = dir / "repro-workspace.toml"
  writeFile(result, text)

proc refusal(path: string): WorkspaceManifestParseError =
  try:
    discard readWorkspaceSettings(path)
  except WorkspaceManifestParseError as e:
    return e[]
  checkpoint("expected a refusal for " & path)
  fail()

suite "repro-workspace.toml settings.v1 decode":

  test "every table decodes":
    let dir = createTempDir("repro-settings-", "")
    defer: removeDir(dir)
    let path = settingsAt(dir, fullSettings)
    let s = readWorkspaceSettings(path)
    check s.schema == schemaWorkspaceSettingsV1
    check not s.isLegacySettings
    check s.path == path
    check s.localPath == ""

    check s.workspace.profile == some("product")
    check s.workspace.default_profile == some("product")
    check s.workspace.roles.mainline == some("dev")
    check s.workspace.roles.unstable == roleBranch("agents")
    check s.workspace.roles.staging == roleAbsent()
    check not s.workspace.roles.stable.isDeclared
    check s.workspace.roles.custom == @[("staging-partner", roleBranch("partner"))]
    check s.rootMainline == some("dev")

    check s.projects.default == @["reprobuild", "codetracer"]
    check s.projects.default_template == some("metacraft-project")
    check s.records.url == some("https://git.example.invalid/acme/records.git")
    check s.records.branch == some("latest")
    check s.records.publish_locks == some(true)
    check s.privateManifestUrl.isNone
    check s.manifestRevision.isNone

    check s.sharedLayers.len == 3
    check s.sharedLayers[0].name == some("internal")
    check s.sharedLayers[0].revision == some("v2026.06")
    check s.sharedLayers[0].visibility == some("org")
    check s.sharedLayers[1].name == some("partner")
    check s.sharedLayers[1].url.isNone
    check s.sharedLayers[2].local_path == some("../shared-manifests")

    check s.profiles.len == 2
    check s.profiles[0][0] == "product"
    check s.profiles[0][1].mainline == some("dev")
    check s.profiles[0][1].unstable == roleBranch("agents")
    check s.profiles[0][1].stable == roleBranch("stable")
    check s.profiles[0][1].custom ==
      @[("staging-partner", roleBranch("staging-partner"))]
    check s.profiles[1][0] == "spec"
    check s.profiles[1][1].mainline == some("latest")
    check s.profileRoles("spec").get().mainline == some("latest")

    check s.customRoles == @[CustomRoleDecl(name: "beta", fallback: "stable"),
      CustomRoleDecl(name: "staging-partner", fallback: "staging")]

    check s.verify.require_signature
    check s.verify.allowed_signers == some("trust/signers")
    check s.verify.allowed_keys == @["ssh-ed25519 AAAA bot"]
    check s.verify.signer_identity == some("bot@manifest")
    check s.develop.org_urls == @["https://git.example.invalid/acme/"]
    check s.locking.route.len == 1
    check s.locking.route[0].backend == "git-checkout"
    check s.locking.route[0].path == some(".repro/records")
    check s.locking.route[0].repos == @["a", "b"]
    check s.foreign_env.auto_load_envrc == some(false)
    check s.foreign_env.auto_load_flake == some(true)

    # The root mainline falls to the profile when [workspace] names none.
    let viaProfile = settingsAt(dir, fullSettings.replace(
      "mainline = \"dev\"\nunstable = \"agents\"\nstaging = false\n", ""))
    check readWorkspaceSettings(viaProfile).rootMainline == some("dev")

  test "the writer emits settings.v1 the reader reads back":
    let dir = createTempDir("repro-settings-", "")
    defer: removeDir(dir)
    let original = readWorkspaceSettings(settingsAt(dir, fullSettings))
    let rewritten = dir / "rewritten" / "repro-workspace.toml"
    writeWorkspaceManifestFile(rewritten, workspaceSettingsText(original))
    check readFile(rewritten).startsWith(
      "schema = \"reprobuild.workspace.settings.v1\"")
    var back = readWorkspaceSettings(rewritten)
    back.path = original.path
    check back.workspace == original.workspace
    check back.projects == original.projects
    check back.records == original.records
    check back.sharedLayers == original.sharedLayers
    check back.profiles == original.profiles
    check back.customRoles == original.customRoles
    check back.verify == original.verify
    check back.develop == original.develop
    check back.locking == original.locking
    check back.foreign_env == original.foreign_env

  test "the strict reader's rules hold in the tree decoder":
    let dir = createTempDir("repro-settings-", "")
    defer: removeDir(dir)
    let base = "schema = \"reprobuild.workspace.settings.v1\"\n"
    for (name, body, keyPath) in [
        ("unknown-top", "garbage = 1\n", "garbage"),
        ("unknown-in-records", "[records]\nurl = \"u\"\nbogus = 1\n",
         "records.bogus"),
        ("unknown-in-profile", "[profiles.p]\nmainline = \"dev\"\nrogue = \"x\"\n",
         "profiles.p.rogue"),
        ("wrong-type", "[records]\npublish_locks = \"yes\"\n",
         "records.publish_locks"),
        ("bad-role", "[workspace]\nunstable = true\n", "workspace.unstable"),
        ("custom-name", "[branch-roles.Beta]\nfallback = \"stable\"\n",
         "branch-roles.Beta"),
        ("no-fallback", "[branch-roles.beta]\n", "branch-roles.beta.fallback"),
        ("tier", "[[manifest]]\nurl = \"u\"\nvisibility = \"secret\"\n",
         "manifest[0].visibility"),
        ("two-sources", "[[manifest]]\nurl = \"u\"\nlocal_path = \"m\"\n" &
         "visibility = \"org\"\n", "manifest[0]"),
        ("no-source", "[[manifest]]\nvisibility = \"org\"\n", "manifest[0]"),
        ("under-repro", "[[manifest]]\nlocal_path = \".repro/mine\"\n" &
         "visibility = \"personal\"\n", "manifest[0].local_path"),
        ("duplicate-name", "[[manifest]]\nname = \"a\"\nvisibility = \"org\"\n" &
         "[[manifest]]\nname = \"a\"\nvisibility = \"org\"\n", "manifest[1].name")]:
      let sub = dir / name
      createDir(sub)
      let e = refusal(settingsAt(sub, base & body))
      check e.keyPath == keyPath
      check e.path == sub / "repro-workspace.toml"
