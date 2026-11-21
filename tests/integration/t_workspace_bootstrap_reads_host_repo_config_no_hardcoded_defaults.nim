## RA-8 — host bootstrap config; no hardcoded org defaults.
##
## `repro workspace init` resolves the manifest URL/branch (and the
## project-to-init via `[projects] default`) from the committed workspace
## settings file (`repro-workspace.toml`: its `[records] url/branch`,
## locatable via `REPRO_WORKSPACE_CONFIG`) rather than from a baked-in org
## URL. The resolution order is:
##
##   explicit `--manifest-url` flag → `repro-workspace.toml` → host repo origin
##
## and when none of those resolves, `init` FAILS LOUD with a clear "no manifest
## configured" diagnostic — the `repro` binary ships no built-in manifest URL.
##
## Cases (all hermetic: local bare repos in a tempdir; `REPRO_WORKSPACE_CONFIG`
## points at a test-authored config so nothing reaches the network):
##
##   A. Config resolves: a config with `[records] url/branch` and
##      `[projects] default = ["myproject"]`, NO `--manifest-url`, NO positional
##      project → init bootstraps `.repro/manifests` from the config's URL and
##      clones the participating repo. (Proves the config feeds the manifest
##      URL/branch AND the default project selection.) The config also
##      declares a credentialed companion manifest as a NAMED `[[manifest]]`
##      layer with no url (Workspace-Settings-Files.md §3); the url comes only
##      from the `repro-workspace.local.toml` beside it (§4), and init must
##      acquire that layer from exactly that url — so no companion url is
##      committed, and none is built in.
##
##   B. Explicit flag beats config: a config pointing at a *wrong* manifest URL
##      plus `--manifest-url=<right>` → init bootstraps from the FLAG's URL, not
##      the config's. (Proves precedence; falsifiable: if config won, the wrong
##      bare — which lacks the project — would fail resolution.)
##
##   C. Fail loud: NO config (`REPRO_WORKSPACE_CONFIG` cleared / absent), NO
##      `--manifest-url`, and a workspace dir that is not a git repo (no origin)
##      → init exits non-zero with a "no manifest configured" message rather
##      than silently using a hardcoded URL.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import shared_clones

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA8 Tester\"")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "RA8 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m first")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  for entry in files:
    let absPath = workPath / entry[0]
    createDir(absPath.splitPath.head)
    writeFile(absPath, entry[1])
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

proc projectTomlBody(libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libATomlBody = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-origin"
mainline = "main"
"""

proc bootstrapConfigBody(manifestUrl: string; projects: string;
                         extra = ""): string =
  ## A `repro-workspace.toml` settings file naming the record store and the
  ## default projects. `projects` is the raw TOML array literal for
  ## `[projects] default`; `extra` is appended verbatim.
  "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
  "[records]\n" &
  "url = \"" & manifestUrl & "\"\n" &
  "branch = \"main\"\n\n" &
  "[projects]\n" &
  "default = " & projects & "\n" & extra

suite "RA-8 — host bootstrap config; no hardcoded org defaults":

  test "t_workspace_bootstrap_reads_host_repo_config_no_hardcoded_defaults":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra8-bootstrap-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # Participating repo origin (shared by both good manifests).
      let libOrigin = scratch / "origin-lib-a.git"
      let libSeed = scratch / "seed-lib-a"
      discard seedOrigin(gitBin, libOrigin, libSeed)

      # The RIGHT public manifest bare repo (carries projects/myproject.toml).
      let manifestBare = scratch / "bare-manifest.git"
      seedBareWithFiles(gitBin, scratch, manifestBare, [
        ("projects/myproject.toml", projectTomlBody(fileUrl(libOrigin))),
        ("repos/lib-a.toml", libATomlBody),
      ])

      # A WRONG manifest bare repo: valid manifest shape but NO myproject.toml.
      # Used in case B to prove the explicit flag overrides the config.
      let wrongManifestBare = scratch / "bare-manifest-wrong.git"
      seedBareWithFiles(gitBin, scratch, wrongManifestBare, [
        ("projects/other.toml",
          "schema = \"reprobuild.workspace.project.v1\"\n\n" &
          "[project]\nname = \"other\"\n" &
          "\nincludes = []\n"),
      ])

      # A private companion manifest bare (content irrelevant; we only assert
      # init acquires it as a manifest layer when its url is supplied by the
      # local settings file `repro-workspace.local.toml`).
      let privateBare = scratch / "bare-manifest-private.git"
      seedBareWithFiles(gitBin, scratch, privateBare, [
        ("projects/_private_placeholder.toml",
          "schema = \"reprobuild.workspace.project.v1\"\n\n" &
          "[project]\nname = \"private\"\n" &
          "\nincludes = []\n"),
      ])

      let manifestCacheRoot = scratch / "manifest-cache"

      # ---- Case A: config resolves URL/branch + default project ------------
      # Also exercises the private companion: the committed file declares a
      # named layer WITHOUT a url (credentialed/SSH URLs are kept out of the
      # committed file), and the sibling `repro-workspace.local.toml` supplies
      # the url for that name.
      block caseA:
        let configDir = scratch / "host-config-a"
        createDir(configDir)
        let configPath = configDir / "repro-workspace.toml"
        writeFile(configPath, bootstrapConfigBody(
          fileUrl(manifestBare), "[\"myproject\"]",
          "\n[[manifest]]\nname = \"private-companion\"\n" &
          "visibility = \"private\"\n"))
        check fileUrl(privateBare) notin readFile(configPath)
        # Sibling local settings: only supplies the credentialed URL.
        writeFile(configDir / "repro-workspace.local.toml",
          "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
          "[[manifest]]\nname = \"private-companion\"\n" &
          "url = \"" & fileUrl(privateBare) & "\"\nbranch = \"main\"\n")

        let workspaceRoot = scratch / "ws-a"
        createDir(workspaceRoot)
        check not dirExists(workspaceRoot / ".repro" / "manifests")

        # No --manifest-url, no positional project name: both come from config.
        let init = runShell(shellCommand(@[
          reproBin, "workspace", "init",
          "--workspace-root=" & workspaceRoot,
        ], env = @[
          (name: "REPRO_MANIFEST_CACHE", value: manifestCacheRoot),
          (name: "REPRO_WORKSPACE_CONFIG", value: configPath),
        ]))
        if init.code != 0:
          checkpoint("case A init output: " & init.output)
        check init.code == 0

        # Bootstrapped from the config's manifest URL.
        check dirExists(manifestCachePath(manifestCacheRoot,
          fileUrl(manifestBare)))
        check fileExists(workspaceRoot / ".repro" / "manifests" / "projects" /
          "myproject.toml")
        # The default project's participating repo was cloned.
        check dirExists(workspaceRoot / "lib-a" / ".git")
        # The private companion (url from the sibling local settings file)
        # was acquired as a manifest layer: a `manifests-<i>-<url>` checkout
        # holding the companion's content. The project it does not declare
        # is unaffected (§4: layers are additive per project).
        var companionCheckouts: seq[string]
        for kind, path in walkDir(workspaceRoot / ".repro"):
          if kind == pcDir and path.lastPathPart.startsWith("manifests-") and
              fileExists(path / "projects" / "_private_placeholder.toml"):
            companionCheckouts.add(path)
        checkpoint("companion checkouts: " & $companionCheckouts)
        check companionCheckouts.len == 1

      # ---- Case B: explicit --manifest-url beats the config ----------------
      block caseB:
        # Config points at the WRONG manifest; the flag points at the right one.
        let configPath = scratch / "host-config-b.toml"
        writeFile(configPath, bootstrapConfigBody(
          fileUrl(wrongManifestBare), "[\"myproject\"]"))

        let workspaceRoot = scratch / "ws-b"
        createDir(workspaceRoot)

        let init = runShell(shellCommand(@[
          reproBin, "workspace", "init", "myproject",
          "--workspace-root=" & workspaceRoot,
          "--manifest-url=" & fileUrl(manifestBare),
          "--manifest-branch=main",
        ], env = @[
          (name: "REPRO_MANIFEST_CACHE", value: manifestCacheRoot),
          (name: "REPRO_WORKSPACE_CONFIG", value: configPath),
        ]))
        if init.code != 0:
          checkpoint("case B init output: " & init.output)
        check init.code == 0

        # Resolution used the FLAG's manifest (which carries myproject.toml).
        # If the config had won, the wrong bare lacks myproject.toml and
        # resolution would have failed.
        check fileExists(workspaceRoot / ".repro" / "manifests" / "projects" /
          "myproject.toml")
        check dirExists(workspaceRoot / "lib-a" / ".git")

      # ---- Case C: nothing resolves → fail loud ----------------------------
      block caseC:
        let workspaceRoot = scratch / "ws-c"
        createDir(workspaceRoot)  # plain dir, NOT a git repo: no origin.

        # Point REPRO_WORKSPACE_CONFIG at a missing file to suppress config
        # ancestor discovery; an empty value means "discover normally".
        # Constrain Git discovery too: when TMPDIR lives under a developer
        # workspace, `git -C <scratch>` would otherwise walk up to that host
        # repo's origin and mask the no-manifest case this block exercises.
        let init = runShell(shellCommand(@[
          reproBin, "workspace", "init",
          "--workspace-root=" & workspaceRoot,
        ], env = @[
          (name: "GIT_CEILING_DIRECTORIES", value: scratch),
          (name: "REPRO_MANIFEST_CACHE", value: manifestCacheRoot),
          (name: "REPRO_WORKSPACE_CONFIG",
            value: scratch / "missing-bootstrap-config.toml"),
        ]))
        check init.code != 0
        check "no manifest configured" in init.output
        # And NO manifest checkout was materialised from a baked-in default.
        check not dirExists(workspaceRoot / ".repro" / "manifests")
