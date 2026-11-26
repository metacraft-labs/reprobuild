## Test support (not a test): NPC-M9's develop-mode fixtures.
##
## A workspace around the CLI world's projects directory: its membership
## manifests (one project manifest, one `repos/*.toml` fragment per declared
## repo, each with its own fetch URL), committed in a manifest checkout
## under `.repro/manifests`, and the workspace state naming the project.
## Git checkouts with a chosen `origin` remote stand for the repos'
## checkouts. Nothing here contacts a network: every URL is the fixture's
## loopback forge or `example.invalid`.

import std/[os, osproc, strutils]

from repro_core/process_streams import drainStream

import repro_workspace_manifests

type
  DeclaredRepoFixture* = object
    name*: string
    path*: string     ## relative to the workspace root
    fetchUrl*: string ## used verbatim: it ends in `.git`

proc sh*(args: openArray[string]; cwd = ""): string =
  let argv = @args
  let p = startProcess(argv[0], workingDir = cwd, args = argv[1 .. ^1],
    options = {poUsePath, poStdErrToStdOut})
  result = drainStream(p.outputStream)
  let rc = p.waitForExit()
  p.close()
  doAssert rc == 0, args.join(" ") & ": " & result

proc gitCommitAll*(dir, message: string) =
  discard sh(["git", "-C", dir, "add", "-A"])
  discard sh(["git", "-C", dir, "-c", "user.name=NPC M9",
    "-c", "user.email=npc-m9@example.invalid", "commit", "-q",
    "--allow-empty", "-m", message])

proc gitHead*(dir: string): string =
  sh(["git", "-C", dir, "rev-parse", "HEAD"]).strip()

proc checkoutAt*(dir, remote: string; files: seq[(string, string)]) =
  ## A git checkout at ``dir`` whose `origin` remote is ``remote``, holding
  ## ``files`` (not committed).
  createDir(dir)
  discard sh(["git", "init", "-q", "-b", "main", dir])
  discard sh(["git", "-C", dir, "remote", "add", "origin", remote])
  for (p, content) in files:
    createDir(parentDir(dir / p))
    writeFile(dir / p, content)

proc writeWorkspace*(ws: string; repos: seq[DeclaredRepoFixture]) =
  ## The workspace at ``ws`` declaring ``repos`` (and nothing else), with
  ## its state naming the project `ws`. Rewrites the manifests in place.
  let manifests = ws / ".repro" / "manifests"
  if dirExists(manifests / "repos"): removeDir(manifests / "repos")
  createDir(manifests / "projects")
  createDir(manifests / "repos")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"ws\"\n\n"
  var includes: seq[string]
  for r in repos:
    doAssert r.fetchUrl.endsWith(".git"), r.fetchUrl
    project.add "[[remote]]\nname = \"r-" & r.name & "\"\nfetch = \"" &
      r.fetchUrl & "\"\n\n"
    includes.add "  \"repos/" & r.name & ".toml\",\n"
    writeFile(manifests / "repos" / (r.name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"" & r.name & "\"\npath = \"" & r.path & "\"\n" &
      "remote = \"r-" & r.name & "\"\nmainline = \"main\"\n")
  project.add "includes = [\n" & includes.join("") & "]\n"
  writeFile(manifests / "projects" / "ws.toml", project)
  if not dirExists(manifests / ".git"):
    discard sh(["git", "init", "-q", "-b", "main", manifests])
  gitCommitAll(manifests, "manifests")
  if not fileExists(ws / ".repro" / "workspace-state.toml"):
    writeWorkspaceBranch(ws, project = "ws", branch = "main")

proc nimbleModule*(stamp: string): string =
  "proc stamp*(): string = \"" & stamp & "\"\n"

proc nimbleText*(requires: seq[string] = @[]; srcDir = "src"): string =
  result = "version = \"1.0.0\"\nsrcDir = \"" & srcDir & "\"\n"
  for r in requires: result.add "requires \"" & r & "\"\n"
