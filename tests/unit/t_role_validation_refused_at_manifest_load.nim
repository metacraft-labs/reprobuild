## Every validation rule of Workspace-Branch-Roles.md §3.5 is refused when the
## manifest is LOADED, naming the file and the key.
##
## §3.5: when the manifest is loaded,
##   * every resolved value is a branch name (no SHA, no `refs/…`, no
##     whitespace);
##   * every profile a fragment names exists;
##   * every custom role a fragment or profile uses is declared under
##     `[branch-roles.*]`;
##   * every fallback chain reaches `mainline` without a cycle (its own test:
##     t_custom_role_fallback_cycle_is_rejected);
##   * every repo resolves `mainline`;
## and each failure names the file and key, and the workspace does not
## resolve. §2.4 adds that a custom role name is lowercase-hyphenated and not
## a built-in name.
##
## Every case starts from the same valid workspace (the positive control,
## resolved first), breaks ONE thing, and asserts that resolving the project
## — what every command does on load — raises a `WorkspaceManifestParseError`
## whose `path` is the file that carries the broken declaration and whose
## `keyPath` is the key. The file is the fragment for a fragment's own
## declaration and the settings file for a profile's or `[workspace]`'s,
## because that is the file the operator has to edit.
##
## One documented exemption is asserted too, so it cannot widen silently: a
## legacy `repo.v1` fragment that declares no `branch` still loads (before the
## roles model such a fragment resolved through `revision` /
## `default_revision`, and the dual-read release keeps reading v1 fragments as
## they always resolved until `repo.v1` is retired); it simply carries no
## roles. A `repo.v2` fragment with no mainline is refused.
##
## No mocks: real files, the real readers and resolver.

import std/[os, strutils, unittest]

import repro_workspace_manifests
import ./branch_roles_fixture

const validSettings =
  "[workspace]\ndefault_profile = \"product\"\n\n" &
  "[profiles.product]\nmainline = \"dev\"\nunstable = \"agents\"\n\n" &
  "[profiles.product.branch-roles]\npartner = \"partner\"\n\n" &
  "[profiles.bare]\nunstable = \"next\"\n\n" &
  "[branch-roles.partner]\nfallback = \"staging\"\n"

proc seedValid(fx: var RolesFixture) =
  fx.writeSettings(validSettings)
  fx.addRepo("core", "profile = \"product\"")
  fx.addRepo("tool", "mainline = \"main\"\nstable = \"stable\"",
    "\n[repo.branch-roles]\npartner = \"tool-partner\"\n")

proc expectRefused(fx: RolesFixture; label, file, key: string;
                   detail = ""): bool =
  ## Whether loading the workspace is refused naming `file` and `key` (and
  ## `detail`). Each part is also `check`ed on its own, so a failure says
  ## which part did not hold.
  let err = refusal(proc () = discard fx.resolveDemo())
  checkpoint(label)
  check not err.isNil
  result = not err.isNil and err.path == file and err.keyPath == key and
    file in err.msg and key in err.msg and detail in err.msg
  if not err.isNil:
    checkpoint(err.msg)
    check err.path == file
    check err.keyPath == key
    check file in err.msg
    check key in err.msg
    if detail.len > 0:
      check detail in err.msg

suite "§3.5 role validation is refused at manifest load":

  test "a valid workspace resolves (positive control)":
    var fx = newRolesFixture("repro-role-valid-")
    defer: fx.dispose()
    fx.seedValid()
    let project = fx.resolveDemo()
    check project.repo("core").role("unstable").branch == "agents"
    check project.repo("core").role("partner").branch == "partner"
    check project.repo("tool").role("partner").branch == "tool-partner"
    check project.repo("tool").role("production").branch == "stable"

  test "resolved values are branch names":
    for (label, repoKeys, key, detail) in [
        ("a SHA mainline", "mainline = \"0123456789abcdef\"", "repo.mainline",
         "commit"),
        ("a full ref", "mainline = \"refs/heads/dev\"", "repo.mainline",
         "fully-qualified"),
        ("whitespace", "mainline = \"dev\"\nunstable = \"my agents\"",
         "repo.unstable", "whitespace"),
        ("a SHA role", "mainline = \"dev\"\nstable = \"abcdef0\"",
         "repo.stable", "commit"),
        ("a git-illegal name", "mainline = \"dev\"\nlts = \"a..b\"",
         "repo.lts", "..")]:
      var fx = newRolesFixture("repro-role-name-")
      defer: fx.dispose()
      fx.seedValid()
      fx.addRepo("bad", repoKeys)
      check fx.expectRefused(label, fx.fragmentPath("bad"), key, detail)

    # A custom role's value, in the fragment and in a profile.
    block:
      var fx = newRolesFixture("repro-role-name-custom-")
      defer: fx.dispose()
      fx.seedValid()
      fx.addRepo("bad", "mainline = \"dev\"",
        "\n[repo.branch-roles]\npartner = \"refs/heads/p\"\n")
      check fx.expectRefused("custom value", fx.fragmentPath("bad"),
        "repo.branch-roles.partner", "fully-qualified")
    block:
      var fx = newRolesFixture("repro-role-name-profile-")
      defer: fx.dispose()
      fx.seedValid()
      fx.writeSettings(validSettings &
        "\n[profiles.broken]\nmainline = \"dev\"\nstable = \"rel ease\"\n")
      check fx.expectRefused("profile value", fx.settingsPath,
        "profiles.broken.stable", "whitespace")
    block:
      var fx = newRolesFixture("repro-role-name-ws-")
      defer: fx.dispose()
      fx.seedValid()
      fx.writeSettings(validSettings.replace("[workspace]\n",
        "[workspace]\nmainline = \"0000000000000000000000000000000000000000\"\n"))
      check fx.expectRefused("root value", fx.settingsPath, "workspace.mainline",
        "commit")
    # The v1 spelling of the mainline is held to the same rule.
    block:
      var fx = newRolesFixture("repro-role-name-v1-")
      defer: fx.dispose()
      fx.seedValid()
      writeFile(fx.fragmentPath("old"),
        "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\nname = \"old\"\n" &
        "path = \"old\"\nurl_prefix = \"acme\"\nbranch = \"refs/heads/main\"\n")
      fx.repos.add("old")
      check fx.expectRefused("v1 branch", fx.fragmentPath("old"), "repo.branch",
        "fully-qualified")

  test "every profile a fragment names exists":
    var fx = newRolesFixture("repro-role-profile-")
    defer: fx.dispose()
    fx.seedValid()
    fx.addRepo("bad", "profile = \"prodcut\"")
    check fx.expectRefused("unknown profile", fx.fragmentPath("bad"), "repo.profile",
      "'prodcut'")

  test "a profile named by the settings file exists":
    for key in ["default_profile", "profile"]:
      var fx = newRolesFixture("repro-role-ws-profile-")
      defer: fx.dispose()
      fx.seedValid()
      fx.writeSettings(validSettings.replace("[workspace]\n",
        "[workspace]\n" & (if key == "profile": "profile = \"ghost\"\n"
                           else: "")).replace(
        "default_profile = \"product\"",
        (if key == "default_profile": "default_profile = \"ghost\""
         else: "default_profile = \"product\"")))
      check fx.expectRefused("workspace." & key, fx.settingsPath,
        "workspace." & key, "'ghost'")

  test "every custom role a fragment or profile uses is declared":
    block:
      var fx = newRolesFixture("repro-role-custom-frag-")
      defer: fx.dispose()
      fx.seedValid()
      fx.addRepo("bad", "mainline = \"dev\"",
        "\n[repo.branch-roles]\nbeta = \"beta\"\n")
      check fx.expectRefused("fragment custom role", fx.fragmentPath("bad"),
        "repo.branch-roles.beta", "[branch-roles.beta]")
    block:
      var fx = newRolesFixture("repro-role-custom-profile-")
      defer: fx.dispose()
      fx.seedValid()
      fx.writeSettings(validSettings &
        "\n[profiles.other]\nmainline = \"dev\"\n\n" &
        "[profiles.other.branch-roles]\nbeta = \"beta\"\n")
      check fx.expectRefused("profile custom role", fx.settingsPath,
        "profiles.other.branch-roles.beta", "[branch-roles.beta]")
    block:
      var fx = newRolesFixture("repro-role-custom-ws-")
      defer: fx.dispose()
      fx.seedValid()
      fx.writeSettings(validSettings &
        "\n[workspace.branch-roles]\nbeta = \"beta\"\n")
      check fx.expectRefused("workspace custom role", fx.settingsPath,
        "workspace.branch-roles.beta", "[branch-roles.beta]")

  test "custom role names are lowercase-hyphenated and not built-in":
    for (name, detail) in [("stable", "built-in"), ("Beta", "lowercase"),
                           ("my_role", "lowercase")]:
      var fx = newRolesFixture("repro-role-custom-name-")
      defer: fx.dispose()
      fx.seedValid()
      fx.writeSettings(validSettings & "\n[branch-roles." & name &
        "]\nfallback = \"stable\"\n")
      check fx.expectRefused("custom name " & name, fx.settingsPath,
        "branch-roles." & name, detail)

  test "every repo resolves mainline":
    # No mainline anywhere: the fragment names a profile that declares none.
    block:
      var fx = newRolesFixture("repro-role-no-mainline-")
      defer: fx.dispose()
      fx.seedValid()
      fx.addRepo("bad", "profile = \"bare\"")
      check fx.expectRefused("profile without mainline", fx.fragmentPath("bad"),
        "repo.mainline", "has no mainline")
    # No settings file, no profile, no mainline.
    block:
      var fx = newRolesFixture("repro-role-no-mainline-bare-")
      defer: fx.dispose()
      fx.addRepo("bad", "unstable = \"agents\"")
      check fx.expectRefused("nothing declares it", fx.fragmentPath("bad"),
        "repo.mainline", "has no mainline")
    # The documented legacy exemption: a v1 fragment without `branch` loads
    # and carries no roles; its revision comes from where it always did.
    block:
      var fx = newRolesFixture("repro-role-v1-legacy-")
      defer: fx.dispose()
      writeFile(fx.fragmentPath("old"),
        "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\nname = \"old\"\n" &
        "path = \"old\"\nurl_prefix = \"acme\"\nrevision = \"v1.2.3\"\n")
      fx.repos.add("old")
      let old = fx.resolveDemo().repo("old")
      check old.roles.len == 0
      check old.branch == ""
      check old.revision == "v1.2.3"
