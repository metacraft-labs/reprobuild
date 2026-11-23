## A fragment's scalar `remote` stays the primary when its `remotes` list
## names only extra remotes.
##
## THE DEFECT. The workspace fragment for the `zgui` fork reads
##
##   remote = "metacraft-labs"
##   remotes = [ { name = "upstream", url_prefix = "zortax", url_suffix = "zgui" } ]
##
## and `repro branch` cloned it from `https://github.com/zortax/zgui`, where
## the fork's branches do not exist (`clone-branch-missing`). The resolver
## looked for a binding named after the scalar, found none, and took the
## list's first entry, the upstream, as the primary. A checkout cloned by hand
## from the right place fared no better: no resolved remote carried the
## scalar's key, so it was used as the git remote name, the sync removed that
## remote as undeclared, and probed `refs/remotes/metacraft-labs/isonim`.
##
## WHAT IS GRADED. The real reader and resolver over real files: the primary
## fetch URL is the `[[remote]]` table's, the upstream stays an extra remote
## under its own name, and a fragment whose list does name the primary keeps
## resolving to that binding (the control for the lookup the fix keeps).
##
## No mocks.

import std/[os, tempfiles, unittest]

import repro_workspace_manifests

const projectToml = """schema = "reprobuild.workspace.project.v1"

includes = [
  "repos/fork.toml",
]

[project]
name = "demo"

[[remote]]
name = "acme"
fetch = "https://git.example.invalid/acme"
"""

const upstreamPrefix = """schema = "reprobuild.workspace.url-prefix.v1"

[url-prefix]
name = "original"
url = "https://git.example.invalid/original"
"""

const forkWithExtraRemote = """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "fork"
path = "fork"
remote = "acme"
mainline = "product"

remotes = [
  { name = "upstream", url_prefix = "original", url_suffix = "fork" },
]
"""

const forkNamingItsPrimary = """schema = "reprobuild.workspace.repo.v2"

[repo]
name = "fork"
path = "fork"
remote = "acme"
mainline = "product"

remotes = [
  { name = "upstream", url_prefix = "original", url_suffix = "fork" },
  { name = "acme", remote = "acme" },
]
"""

suite "a scalar remote stays primary beside extra remotes":
  test "the primary is the [[remote]] table's, the upstream an extra remote":
    let root = createTempDir("repro-scalar-remote-", "")
    defer: removeDir(root)
    createDir(root / "projects")
    createDir(root / "repos")
    createDir(root / "url-prefixes")
    writeFile(root / "projects" / "demo.toml", projectToml)
    writeFile(root / "url-prefixes" / "original.toml", upstreamPrefix)

    writeFile(root / "repos" / "fork.toml", forkWithExtraRemote)
    let resolved = resolveProject(root / "projects" / "demo.toml")
    require resolved.repos.len == 1
    let repo = resolved.repos[0]
    check repo.fetchUrl == "https://git.example.invalid/acme/fork"
    check repo.projectRemote == "acme"
    var upstreamUrl = ""
    for r in repo.remotes:
      if r.localName == "upstream": upstreamUrl = r.fetchUrl
    check upstreamUrl == "https://git.example.invalid/original/fork"
    check repo.remotes.len == 2
    check repo.remotes[0].fetchUrl == "https://git.example.invalid/acme/fork"
    # The primary is a resolved remote carrying the scalar's key, so the
    # checkout's git remote for it is `origin`. Without it the key matched no
    # resolved remote, the key itself was taken as the git remote name, and
    # `repro branch` removed that remote (it was not among `remotes`) and then
    # probed `refs/remotes/metacraft-labs/<branch>` -- `probe_failed` on a
    # checkout cloned by hand from the right place.
    check repo.remotes[0].localName == "origin"
    check repo.remotes[0].projectRemote == repo.projectRemote

  test "a list that names the primary keeps resolving to that binding":
    let root = createTempDir("repro-scalar-remote-named-", "")
    defer: removeDir(root)
    createDir(root / "projects")
    createDir(root / "repos")
    createDir(root / "url-prefixes")
    writeFile(root / "projects" / "demo.toml", projectToml)
    writeFile(root / "url-prefixes" / "original.toml", upstreamPrefix)

    writeFile(root / "repos" / "fork.toml", forkNamingItsPrimary)
    let resolved = resolveProject(root / "projects" / "demo.toml")
    require resolved.repos.len == 1
    let repo = resolved.repos[0]
    check repo.fetchUrl == "https://git.example.invalid/acme/fork"
    check repo.remotes.len == 2
