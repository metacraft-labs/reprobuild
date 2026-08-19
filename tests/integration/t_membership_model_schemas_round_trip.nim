## Workspace-Membership-Model.md step 1 — the new manifest kinds parse, and the
## properties the model is built on are enforced by the schema rather than by
## convention.
##
## This lands the readers only. Nothing consumes them yet, and the existing
## `includes` / `remote` / `revision` spellings still work untouched — the
## migration's step 1 is deliberately behaviour-preserving.
##
## Asserted:
##   1. A url-prefix manifest round-trips.
##   2. A repo-set round-trips, and `members` holds NAMES, not paths.
##   3. A repo-set REFUSES identity fields. This is the property that keeps a
##      shared set from drifting into a half-project, and it has to be enforced
##      by the strict decode: a comment saying "don't put default_revision here"
##      is not a mechanism.
##   4. A repo fragment accepts `branch`, `url_prefix`, `url_suffix`, and
##      per-binding `url_suffix` on a secondary remote — the fork case that was
##      previously inexpressible, because one shared `name` could only ever
##      compose `<other-prefix>/<same-name>`.
##
## No mocks: the real readers are driven against real files on disk.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

proc write(dir, name, body: string): string =
  result = dir / name
  writeFile(result, body)

suite "membership model — new manifest kinds":

  test "t_url_prefix_round_trips":
    let d = createTempDir("repro-mm-prefix-", "")
    defer: removeDir(d)
    let f = write(d, "metacraft-labs.toml", """
schema = "reprobuild.workspace.url-prefix.v1"

[url-prefix]
name = "metacraft-labs"
url = "https://github.com/metacraft-labs"
""")
    let m = readUrlPrefix(f)
    check m.`url-prefix`.name == "metacraft-labs"
    check m.`url-prefix`.url == "https://github.com/metacraft-labs"

  test "t_repo_set_members_are_names_not_paths":
    let d = createTempDir("repro-mm-set-", "")
    defer: removeDir(d)
    let f = write(d, "shared-infrastructure.toml", """
schema = "reprobuild.workspace.repo-set.v1"

[repo-set]
name = "shared-infrastructure"

members = ["infra", "garm", "metacraft-dev-guidelines"]
""")
    let m = readRepoSet(f)
    check m.`repo-set`.name == "shared-infrastructure"
    check m.members == @["infra", "garm", "metacraft-dev-guidelines"]
    # Names, not `repos/<name>.toml` paths — consistent with `depends`, and the
    # reason `includes` is being retired.
    for entry in m.members:
      check not entry.contains("/")
      check not entry.endsWith(".toml")

  test "t_repo_set_refuses_identity_fields":
    let d = createTempDir("repro-mm-identity-", "")
    defer: removeDir(d)
    # `default_revision` is the field that would make a shared set resolve
    # differently depending on who referenced it. It must be unrepresentable,
    # not merely discouraged.
    let f = write(d, "bad.toml", """
schema = "reprobuild.workspace.repo-set.v1"

[repo-set]
name = "bad"
default_revision = "dev"

members = ["infra"]
""")
    var refused = false
    try:
      discard readRepoSet(f)
    except WorkspaceManifestParseError:
      refused = true
    check refused

  test "t_repo_fragment_expresses_a_fork_upstream":
    let d = createTempDir("repro-mm-fork-", "")
    defer: removeDir(d)
    # The case that could not be written before: a fork whose upstream lives at
    # a DIFFERENT path. Sharing one `name` across bindings could only compose
    # `kitware/reprobuild-cmake`; the upstream is `kitware/CMake`.
    let f = write(d, "reprobuild-cmake.toml", """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "reprobuild-cmake"
path = "reprobuild-cmake"
branch = "reprobuild"
url_prefix = "metacraft-labs"
remotes = [{ name = "upstream", url_prefix = "kitware", url_suffix = "CMake" }]
""")
    let m = readRepoFragment(f)
    check m.repo.name == "reprobuild-cmake"
    check m.repo.branch.get() == "reprobuild"
    check m.repo.url_prefix.get() == "metacraft-labs"
    check m.repo.remotes.len == 1
    let up = m.repo.remotes[0]
    check up.name == "upstream"          # the LOCAL git remote name
    check up.url_prefix == "kitware"     # a different prefix...
    check up.url_suffix == "CMake"       # ...at a different path

  test "t_existing_spellings_still_parse":
    let d = createTempDir("repro-mm-compat-", "")
    defer: removeDir(d)
    # Step 1 is additive: an unconverted fragment must read exactly as before.
    let f = write(d, "legacy.toml", """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "legacy"
path = "legacy"
remote = "metacraft-labs"
revision = "dev"
""")
    let m = readRepoFragment(f)
    check m.repo.remote.get() == "metacraft-labs"
    check m.repo.revision.get() == "dev"
    check m.repo.branch.isNone()
    check m.repo.url_prefix.isNone()
