## A workspace's settings layers compose before any state file exists.
##
## Workspace-Settings-Files.md §4 "Layer resolution": layers compose "the root
## repository, then the shared file's `[[manifest]]` entries in order, then
## the local file's unnamed entries in order", and a shared named layer with
## no url from either file is "reported and skipped". Nothing in that rule
## mentions `.repro/workspace-state.toml`: the settings files are committed
## (and the local one sits beside them), so they exist in a fresh clone of the
## workspace repository before `repro workspace init` / `enable` has written
## any state. A workspace-resolving verb run there with a `<project>` must
## therefore see the layers' repos, and must report the skipped layer.
##
## The fixture is a real workspace root with NO `.repro/` at all:
##
##   * its own `projects/demo.toml` + `repos/core.toml` (the base layer);
##   * `repro-workspace.toml` declaring two named layers: `partner`, whose url
##     `repro-workspace.local.toml` supplies (a real `file://` bare git repo
##     carrying `projects/demo.toml` + `repos/partner-lib.toml`), and
##     `absent`, which no file supplies a url for.
##
## Every leg runs the REAL `repro` binary:
##
##   1. `repro workspace list demo --json` lists `core` (base layer) AND
##      `partner-lib` (cloned from the partner layer), and says on stderr,
##      exactly once, that layer `absent` was skipped. It writes no state
##      file — composing is a read.
##   2. `repro workspace manifests --json` enumerates the composed layer stack
##      (the root base layer and `partner`) with no state file.
##   3. A settings file that declares no layer changes nothing: a root whose
##      `repro-workspace.toml` carries only `[records]` and no state resolves
##      `workspace list demo` to exactly the output of the same root with no
##      settings file at all, and prints nothing on stderr. A root carrying
##      the settings file only under its RETIRED name (`.repro-workspace.toml`,
##      bootstrap.v1) is not read as "no settings": `workspace list demo` is
##      refused, naming the file and its replacement, and writes nothing.
##   4. Materializing verbs check out what a layer adds. A root (no state)
##      whose `projects/demo.toml` declares repo `core`, and whose
##      `repro-workspace.toml` declares a `local_path` layer whose own
##      `projects/demo.toml` adds repo `extra` (both real `file://` remotes):
##      `repro ws enable demo` clones `core` AND `extra`, and a following
##      unscoped `repro sync --dry-run` plans no clone of `extra`.
##   5. Same root, fresh copy: `repro sync demo` clones `extra`.
##   6. Same, with the layer recorded in the state file under its RETIRED
##      name and schema (`.repro/workspace.toml`, `local.v1` `[[manifest]]`):
##      `repro sync demo` refuses, naming `repro health --fix` and cloning
##      nothing; after `repro health --fix` (which moves the layer to
##      `repro-workspace.local.toml`, §8 step 2) `repro sync demo` clones
##      `extra`.
##
##   7–10. Scoping by names that are not a project every layer declares
##      (a root WITH state — `workspace-state.toml` recording `demo` — whose
##      `repro-workspace.local.toml` declares the layer: project `demo` =
##      root `core` + layer `extra`, root-only project `other` = `solo`, root
##      variant `demo-v` based on `demo`; and a fresh settings-file root
##      (no state) whose layer alone
##      declares `lonly` = `lr`): `sync demo-v --dry-run` plans the variant's
##      one repo; `sync other --dry-run` plans 0 repos (the active project does
##      not include `solo`); `sync nosuch` is an unknown project; `sync lonly`
##      clones `lr` only. Layers compose additively — a layer that does not
##      declare the project contributes nothing to it.
##
##   11. Settings-file layers are additive per project
##      (Workspace-Settings-Files.md §4 "Layers are additive per project"):
##      with a settings-file partner layer declaring only `demo`,
##      `ws enable other` resolves fully and clones the root's `solo`;
##      `sync other`, `workspace list other` and `ws status` work; `demo` still
##      gets the partner's `pextra`.
##   12. Both settings files (shared layer `../partner` + personal layer
##      `../statelayer`, both declaring only `demo`): while `../statelayer`
##      is still recorded in the state file, `workspace list demo` refuses
##      (the state file carries no layers) naming `repro health --fix`; once
##      `--fix` has moved it to `repro-workspace.local.toml`, `workspace list
##      demo` unions all three layers and `ws enable other` blames neither
##      layer — the per-project additivity holds for both files, and the M8
##      rule that a state-file layer must declare the project is gone with
##      the state-file layers.
##
## What each assertion guards. `"partner-lib" in names` (leg 1) is the one
## that fails when the routing gate (`isCompositionalWorkspaceToml`) composes
## settings layers only with a state file: measured, that mutation fails it and
## leaves the skip-report assertions passing, because the skip report does not
## come from the composer — it comes from the state-read hook that reports a
## settings-marked root's notices with or without layers composing
## (`workspaceTomlPath` -> `reportWorkspaceNotices`). The skip-count
## assertions guard that report (once, not zero, not twice); the `--json`
## parse and the "no state written" checks guard that composing stays a
## read. The `extra` clone assertions of legs 4–6 fail when `sync <project>`'s
## scope filter derives the named project's repos from the root layer alone
## (`resolveNamedProjectOrVariant` reading `projects/<name>.toml` only):
## the composer returns `extra`, and the filter dropped it. Legs 7–10 fail
## when every layer must declare a project the composer composes (legs 8 and
## 10 error with "does not declare project"), when a variant is sent to the
## composer (leg 7), or when a name no layer declares is not reported as
## unknown (leg 9). Legs 11–12 fail when settings-file layers are composed
## strictly (enable reports "could not resolve", list/sync/status of `other`
## error) — for the shared file's layers (leg 11) and the local file's
## (leg 12). The refusal assertions of legs 3, 6 and 12 fail when a retired
## file (settings file name, state file name, layers in the state file) is
## silently read as absent, or read as what it used to mean.
##
## No mocks. Skip rule: skip only when `git` is missing from PATH (the partner
## layer is a real repository the real composer clones).

import std/[json, os, osproc, sequtils, streams, strtabs, strutils, tempfiles,
  unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  ## The real binary's exit code, stdout and stderr, read separately so the
  ## skip report is looked for where it belongs and `--json` stays parseable.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  # The fixture's settings files must be found by discovery, not by an
  # inherited override pointing elsewhere.
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(reproBinary(), args = @args, env = env, options = {})
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc requireSuccess(command: string) =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  ## A one-commit bare repository holding `files`, so the layer's url is a
  ## real `file://` remote with `main`.
  let work = scratch / ("seed-" & extractFilename(barePath))
  requireSuccess(q(gitBin) & " init -q -b main " & q(work))
  requireSuccess(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  requireSuccess(q(gitBin) & " -C " & q(work) & " config user.name Tester")
  for (rel, body) in files:
    createDir((work / rel).parentDir)
    writeFile(work / rel, body)
  requireSuccess(q(gitBin) & " -C " & q(work) & " add -A")
  requireSuccess(q(gitBin) & " -C " & q(work) & " commit -q -m fixture")
  requireSuccess(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))

proc projectToml(includes: openArray[string]): string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "includes = [\n"
  for inc in includes:
    result.add("  \"" & inc & "\",\n")
  result.add("]\n\n[project]\nname = \"demo\"\n" &
    "\n[[remote]]\nname = \"acme\"\n" &
    "fetch = \"https://git.example.invalid/acme\"\n")

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"acme\"\nmainline = \"main\"\n"

proc seedRoot(root: string) =
  ## A workspace root's own membership (the base layer), and nothing else.
  createDir(root / "projects")
  createDir(root / "repos")
  writeFile(root / "projects" / "demo.toml", projectToml(["repos/core.toml"]))
  writeFile(root / "repos" / "core.toml", fragmentToml("core"))

proc repoNames(listJson: string): seq[string] =
  for repo in parseJson(listJson)["repos"]:
    result.add(repo["name"].getStr())

const skipMarker = "manifest layer 'absent'"

proc seedBareRepo(gitBin, scratch, barePath: string) =
  ## A bare repository with one commit on `main`, to be cloned as a member.
  seedBareWithFiles(gitBin, scratch, barePath, [("README", "fixture\n")])

proc remoteProjectToml(fetch, repo: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\nincludes = [\"repos/" &
    repo & ".toml\"]\n\n[project]\nname = \"demo\"\n" &
    "\n[[remote]]\n" &
    "name = \"acme\"\nfetch = \"" & fetch & "\"\n"

proc seedClonableLayeredRoot(root, layer, fetch: string) =
  ## `root` declares `demo` = `core`; the layer at `layer` adds `extra` to
  ## `demo`. Both repos clone from `fetch`. No state file, no settings file:
  ## the caller decides where the layer is declared.
  createDir(root / "projects")
  createDir(root / "repos")
  writeFile(root / "projects" / "demo.toml", remoteProjectToml(fetch, "core"))
  writeFile(root / "repos" / "core.toml", fragmentToml("core"))
  createDir(layer / "projects")
  createDir(layer / "repos")
  writeFile(layer / "projects" / "demo.toml",
    remoteProjectToml(fetch, "extra"))
  writeFile(layer / "repos" / "extra.toml", fragmentToml("extra"))

proc isCheckout(dir: string): bool =
  dirExists(dir / ".git") or fileExists(dir / ".git")

const layerSettings = "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
  "[[manifest]]\nlocal_path = \"../layer\"\nvisibility = \"public\"\n"
  ## A shared settings file declaring the `../layer` layer.

const localLayerSettings =
  "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
  "[[manifest]]\nlocal_path = \"../layer\"\nvisibility = \"public\"\n"
  ## The same layer declared in one person's local settings file.

suite "settings layers apply without a state file":

  test "t_settings_layers_apply_without_state_file":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the partner layer is a real bare repository " &
        "cloned by the real composer, and nothing else proves its repos " &
        "reach a workspace that has no state file")
    else:
      let scratch = createTempDir("repro-layers-no-state-", "")
      defer: removeDir(scratch)

      let partnerBare = scratch / "partner-manifests.git"
      seedBareWithFiles(gitBin, scratch, partnerBare, [
        ("projects/demo.toml", projectToml(["repos/partner-lib.toml"])),
        ("repos/partner-lib.toml", fragmentToml("partner-lib"))])

      let root = scratch / "workspace"
      seedRoot(root)
      writeFile(root / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[[manifest]]\nname = \"partner\"\nvisibility = \"team\"\n\n" &
        "[[manifest]]\nname = \"absent\"\nvisibility = \"team\"\n")
      writeFile(root / "repro-workspace.local.toml",
        "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
        "[[manifest]]\nname = \"partner\"\nurl = \"" & fileUrl(partnerBare) &
        "\"\nbranch = \"main\"\n")
      # The precondition the whole test is about.
      require not dirExists(root / ".repro")

      # Leg 1 — the layer's repos are composed, the skipped layer reported.
      let listed = runRepro(["workspace", "list", "demo", "--json",
        "--workspace-root=" & root])
      checkpoint("workspace list stderr: " & listed.stderr)
      checkpoint("workspace list stdout: " & listed.stdout)
      check listed.code == 0
      let names = repoNames(listed.stdout)
      check "core" in names
      check "partner-lib" in names
      check listed.stderr.count(skipMarker) == 1
      check "the layer is skipped" in listed.stderr
      # Composing is a read: no state was written by it.
      check not fileExists(root / ".repro" / "workspace-state.toml")
      check not fileExists(root / ".repro" / "workspace.toml")

      # Leg 2 — the layer stack is enumerated with no state file.
      let manifests = runRepro(["workspace", "manifests", "--json",
        "--workspace-root=" & root])
      checkpoint("workspace manifests stderr: " & manifests.stderr)
      checkpoint("workspace manifests stdout: " & manifests.stdout)
      check manifests.code == 0
      let doc = parseJson(manifests.stdout)
      check doc["hasLayeredWorkspace"].getBool()
      let layerUrls = doc["layers"].getElems().mapIt(it["url"].getStr())
      check fileUrl(partnerBare) in layerUrls
      check doc["layers"].len == 2
      check manifests.stderr.count(skipMarker) == 1

      # Leg 3 — a settings file declaring no layer (only `[records]`; no
      # state) resolves exactly as a root with no settings file at all.
      let plain = scratch / "plain"
      seedRoot(plain)
      let legacy = scratch / "legacy"
      seedRoot(legacy)
      writeFile(legacy / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[records]\nurl = \"https://git.example.invalid/acme/records.git\"\n" &
        "branch = \"latest\"\n")
      let plainList = runRepro(["workspace", "list", "demo",
        "--workspace-root=" & plain])
      let legacyList = runRepro(["workspace", "list", "demo",
        "--workspace-root=" & legacy])
      checkpoint("legacy stderr: " & legacyList.stderr)
      check plainList.code == 0
      check legacyList.code == 0
      check legacyList.stdout.replace(legacy, "<root>") ==
        plainList.stdout.replace(plain, "<root>")
      check legacyList.stderr == ""
      check not dirExists(legacy / ".repro")
      # ...while the settings file under its RETIRED name is refused with the
      # remedy, never read as "no settings" (which would drop its policy).
      let retired = scratch / "retired"
      seedRoot(retired)
      writeFile(retired / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\nurl = \"https://git.example.invalid/acme/records.git\"\n" &
        "branch = \"latest\"\n")
      let retiredList = runRepro(["workspace", "list", "demo",
        "--workspace-root=" & retired])
      checkpoint("retired settings stderr: " & retiredList.stderr)
      check retiredList.code != 0
      check ".repro-workspace.toml" in retiredList.stderr
      check "Rename it to `repro-workspace.toml`" in retiredList.stderr
      check not dirExists(retired / ".repro")

      # Legs 4-6 — materializing verbs check out the repos a layer adds.
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBareRepo(gitBin, scratch, remotes / "core")
      seedBareRepo(gitBin, scratch, remotes / "extra")
      let fetch = fileUrl(remotes)

      # Leg 4 — `ws enable demo` with the layer in the settings file.
      let enableRoot = scratch / "enable" / "ws"
      seedClonableLayeredRoot(enableRoot, scratch / "enable" / "layer", fetch)
      writeFile(enableRoot / "repro-workspace.toml", layerSettings)
      let enabled = runRepro(["workspace", "enable", "demo",
        "--workspace-root=" & enableRoot])
      checkpoint("enable stdout: " & enabled.stdout)
      checkpoint("enable stderr: " & enabled.stderr)
      check enabled.code == 0
      check isCheckout(enableRoot / "core")
      check isCheckout(enableRoot / "extra")
      let after = runRepro(["sync", "--dry-run",
        "--workspace-root=" & enableRoot])
      checkpoint("sync --dry-run after enable: " & after.stdout & after.stderr)
      check after.code == 0
      check "[clone] extra" notin after.stdout

      # Leg 5 — `sync demo` with the layer in the settings file, no state.
      let syncRoot = scratch / "sync" / "ws"
      seedClonableLayeredRoot(syncRoot, scratch / "sync" / "layer", fetch)
      writeFile(syncRoot / "repro-workspace.toml", layerSettings)
      let synced = runRepro(["sync", "demo", "--workspace-root=" & syncRoot])
      checkpoint("sync demo: " & synced.stdout & synced.stderr)
      check synced.code == 0
      check isCheckout(syncRoot / "core")
      check isCheckout(syncRoot / "extra")

      # Leg 6 — the layer recorded in the state file under its RETIRED name
      # and schema. `sync demo` refuses with the remedy and clones nothing;
      # `repro health --fix` moves the file and its layer
      # (Workspace-Settings-Files.md §8 step 2), and then `sync demo` clones
      # what the layer adds.
      let stateRoot = scratch / "state" / "ws"
      seedClonableLayeredRoot(stateRoot, scratch / "state" / "layer", fetch)
      createDir(stateRoot / ".repro")
      writeFile(stateRoot / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\n\n" &
        "[[manifest]]\nlocal_path = \".\"\nvisibility = \"public\"\n\n" &
        "[[manifest]]\nlocal_path = \"../layer\"\nvisibility = \"public\"\n")
      let stateRefused = runRepro(["sync", "demo",
        "--workspace-root=" & stateRoot])
      checkpoint("retired state sync demo: " & stateRefused.stdout &
        stateRefused.stderr)
      check stateRefused.code != 0
      check "repro health --fix" in stateRefused.stderr
      check not dirExists(stateRoot / "core")
      check not dirExists(stateRoot / "extra")
      let stateFixed = runRepro(["health", "--fix", "--offline",
        "--workspace-root=" & stateRoot])
      checkpoint("health --fix: " & stateFixed.stdout & stateFixed.stderr)
      check not fileExists(stateRoot / ".repro" / "workspace.toml")
      check fileExists(stateRoot / ".repro" / "workspace-state.toml")
      check fileExists(stateRoot / "repro-workspace.local.toml")
      let stateSynced = runRepro(["sync", "demo",
        "--workspace-root=" & stateRoot])
      checkpoint("state sync demo: " & stateSynced.stdout & stateSynced.stderr)
      check stateSynced.code == 0
      check isCheckout(stateRoot / "core")
      check isCheckout(stateRoot / "extra")

      # Legs 7-10 — scoping by a name that is not a project every layer
      # declares. Layers compose additively, so a layer that does not declare
      # the named project contributes nothing to it; variants and repo-sets
      # resolve from the root as they always did.
      seedBareRepo(gitBin, scratch, remotes / "solo")
      seedBareRepo(gitBin, scratch, remotes / "lr")
      let scopeRoot = scratch / "scope" / "ws"
      let scopeLayer = scratch / "scope" / "layer"
      seedClonableLayeredRoot(scopeRoot, scopeLayer, fetch)
      writeFile(scopeRoot / "projects" / "other.toml",
        remoteProjectToml(fetch, "solo").replace("name = \"demo\"",
          "name = \"other\""))
      writeFile(scopeRoot / "repos" / "solo.toml", fragmentToml("solo"))
      createDir(scopeRoot / "variants")
      writeFile(scopeRoot / "variants" / "demo-v.toml",
        "schema = \"reprobuild.workspace.variant.v1\"\n\n[variant]\n" &
        "name = \"demo-v\"\nbase = \"projects/demo.toml\"\n")
      writeFile(scopeLayer / "projects" / "lonly.toml",
        remoteProjectToml(fetch, "lr").replace("name = \"demo\"",
          "name = \"lonly\""))
      writeFile(scopeLayer / "repos" / "lr.toml", fragmentToml("lr"))
      # This root records state (the active project `demo`), and its layer
      # is one person's, in the local settings file beside a shared file
      # that declares none.
      createDir(scopeRoot / ".repro")
      writeFile(scopeRoot / ".repro" / "workspace-state.toml",
        "schema = \"reprobuild.workspace.state.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\n")
      writeFile(scopeRoot / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n")
      writeFile(scopeRoot / "repro-workspace.local.toml", localLayerSettings)

      # Leg 7 — a VARIANT of the composed project scopes from the root, as
      # before: the variant's base is the root's `demo` (core).
      let variantRun = runRepro(["sync", "demo-v", "--dry-run",
        "--workspace-root=" & scopeRoot])
      checkpoint("sync demo-v: " & variantRun.stdout & variantRun.stderr)
      check variantRun.code == 0
      check "will reconcile 1 repo(s) across project(s) demo-v" in
        variantRun.stdout
      check "[clone] core" in variantRun.stdout

      # Leg 8 — a project only the ROOT declares: the layer lacking it
      # contributes nothing, and the scope is the root's `solo`, which the
      # active project `demo` does not include — nothing to reconcile, as
      # before.
      let rootOnlyRun = runRepro(["sync", "other", "--dry-run",
        "--workspace-root=" & scopeRoot])
      checkpoint("sync other: " & rootOnlyRun.stdout & rootOnlyRun.stderr)
      check rootOnlyRun.code == 0
      check "will reconcile 0 repo(s) across project(s) other" in
        rootOnlyRun.stdout

      # Leg 9 — a name NO layer declares is still an unknown project.
      let unknownRun = runRepro(["sync", "nosuch", "--dry-run",
        "--workspace-root=" & scopeRoot])
      checkpoint("sync nosuch: " & unknownRun.stdout & unknownRun.stderr)
      check unknownRun.code != 0
      check "unknown project 'nosuch'" in unknownRun.stderr

      # Leg 10 — a project only a LATER layer declares, in a fresh root (no
      # state) whose settings file declares that layer: `sync lonly` clones
      # the layer's `lr` and nothing of the root's `demo`.
      let laterRoot = scratch / "later" / "ws"
      let laterLayer = scratch / "later" / "layer"
      seedClonableLayeredRoot(laterRoot, laterLayer, fetch)
      writeFile(laterLayer / "projects" / "lonly.toml",
        remoteProjectToml(fetch, "lr").replace("name = \"demo\"",
          "name = \"lonly\""))
      writeFile(laterLayer / "repos" / "lr.toml", fragmentToml("lr"))
      writeFile(laterRoot / "repro-workspace.toml", layerSettings)
      let laterRun = runRepro(["sync", "lonly",
        "--workspace-root=" & laterRoot])
      checkpoint("sync lonly: " & laterRun.stdout & laterRun.stderr)
      check laterRun.code == 0
      check isCheckout(laterRoot / "lr")
      check not dirExists(laterRoot / "core")

      # Legs 11-12 — settings-file layers are additive per project
      # (Workspace-Settings-Files.md §4 "Layers are additive per project"),
      # in the shared file and the local one alike.
      seedBareRepo(gitBin, scratch, remotes / "pextra")
      proc seedPartnerRoot(root, partner: string) =
        ## `root`: project `demo` = `core`, project `other` = `solo`.
        ## `partner`: a layer declaring only `demo` (adding `pextra`).
        createDir(root / "projects")
        createDir(root / "repos")
        writeFile(root / "projects" / "demo.toml",
          remoteProjectToml(fetch, "core"))
        writeFile(root / "repos" / "core.toml", fragmentToml("core"))
        writeFile(root / "projects" / "other.toml",
          remoteProjectToml(fetch, "solo").replace("name = \"demo\"",
            "name = \"other\""))
        writeFile(root / "repos" / "solo.toml", fragmentToml("solo"))
        createDir(partner / "projects")
        createDir(partner / "repos")
        writeFile(partner / "projects" / "demo.toml",
          remoteProjectToml(fetch, "pextra"))
        writeFile(partner / "repos" / "pextra.toml", fragmentToml("pextra"))
        writeFile(root / "repro-workspace.toml",
          "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
          "[[manifest]]\nlocal_path = \"../partner\"\n" &
          "visibility = \"public\"\n")

      # Leg 11 — a project the settings-file partner layer does not declare.
      let partnerRoot = scratch / "partner-case" / "ws"
      seedPartnerRoot(partnerRoot, scratch / "partner-case" / "partner")
      # The project the partner layer DOES declare gets its repos (no state yet, so the
      # named project is what `list` composes).
      let listDemo = runRepro(["workspace", "list", "demo", "--json",
        "--workspace-root=" & partnerRoot])
      check listDemo.code == 0
      check repoNames(listDemo.stdout) == @["core", "pextra"]
      let enabledOther = runRepro(["workspace", "enable", "other",
        "--workspace-root=" & partnerRoot])
      checkpoint("enable other: " & enabledOther.stdout & enabledOther.stderr)
      check enabledOther.code == 0
      check "could not resolve" notin enabledOther.stderr
      check isCheckout(partnerRoot / "solo")
      check not dirExists(partnerRoot / "pextra")
      let syncOther = runRepro(["sync", "other", "--dry-run",
        "--workspace-root=" & partnerRoot])
      checkpoint("sync other: " & syncOther.stdout & syncOther.stderr)
      check syncOther.code == 0
      check "will reconcile 1 repo(s) across project(s) other" in
        syncOther.stdout
      let listOther = runRepro(["workspace", "list", "other", "--json",
        "--workspace-root=" & partnerRoot])
      checkpoint("list other: " & listOther.stdout & listOther.stderr)
      check listOther.code == 0
      check repoNames(listOther.stdout) == @["solo"]
      let status = runRepro(["workspace", "status",
        "--workspace-root=" & partnerRoot])
      checkpoint("ws status: " & status.stdout & status.stderr)
      check status.code == 0

      # Leg 12 — both settings files: a layer still recorded in the state
      # file is refused with the remedy; moved to the local settings file,
      # it composes additively like the shared file's layer.
      let mixedRoot = scratch / "mixed" / "ws"
      seedPartnerRoot(mixedRoot, scratch / "mixed" / "partner")
      let stateLayer = scratch / "mixed" / "statelayer"
      createDir(stateLayer / "projects")
      createDir(stateLayer / "repos")
      writeFile(stateLayer / "projects" / "demo.toml",
        remoteProjectToml(fetch, "extra"))
      writeFile(stateLayer / "repos" / "extra.toml", fragmentToml("extra"))
      createDir(mixedRoot / ".repro")
      writeFile(mixedRoot / ".repro" / "workspace-state.toml",
        "schema = \"reprobuild.workspace.state.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\n\n" &
        "[[manifest]]\nlocal_path = \"../statelayer\"\n" &
        "visibility = \"public\"\n")
      let layersInState = runRepro(["workspace", "list", "demo", "--json",
        "--workspace-root=" & mixedRoot])
      checkpoint("layers in state: " & layersInState.stdout &
        layersInState.stderr)
      check layersInState.code != 0
      check "the state file carries no `[[manifest]]` layers" in
        layersInState.stderr
      check "repro health --fix" in layersInState.stderr
      let mixedFixed = runRepro(["health", "--fix", "--offline",
        "--workspace-root=" & mixedRoot])
      checkpoint("mixed health --fix: " & mixedFixed.stdout & mixedFixed.stderr)
      check fileExists(mixedRoot / "repro-workspace.local.toml")
      check "../statelayer" in readFile(mixedRoot / "repro-workspace.local.toml")
      check "[[manifest]]" notin
        readFile(mixedRoot / ".repro" / "workspace-state.toml")
      let mixedDemo = runRepro(["workspace", "list", "demo", "--json",
        "--workspace-root=" & mixedRoot])
      checkpoint("mixed list demo: " & mixedDemo.stdout & mixedDemo.stderr)
      check mixedDemo.code == 0
      # §4 order: the root, then the shared file's layers, then the local
      # file's — so the moved `../statelayer` now composes LAST.
      check repoNames(mixedDemo.stdout) == @["core", "pextra", "extra"]
      # `ws enable other` composes the NAMED project across the layers (a
      # verb with state composes the recorded project for `list`), so it is
      # where the per-layer rule shows: neither the local file's layer nor
      # the shared file's is blamed for not declaring `other`.
      let mixedOther = runRepro(["workspace", "enable", "other", "--no-sync",
        "--workspace-root=" & mixedRoot])
      checkpoint("mixed enable other: " & mixedOther.stdout & mixedOther.stderr)
      check mixedOther.code == 0
      check "could not resolve" notin mixedOther.stderr
      check "'../statelayer' does not declare" notin mixedOther.stderr
      check "'../partner' does not declare" notin mixedOther.stderr
