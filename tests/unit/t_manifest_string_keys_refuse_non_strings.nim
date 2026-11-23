## A text key in ANY strict-decoded manifest takes a TOML string: a boolean,
## number or other non-string written for it is refused at load, naming the
## file and the key path, rather than read as text.
##
## The pinned typed TOML decoder turns a boolean or a number into text when
## the field it fills is a string, so before this rule held for every reader
## `[url-prefix] url = false` composed clone URLs under the prefix "false" and
## `member_repos = [true]` named a member repo called "true". The rule is
## Workspace-Manifests.md §"Common Conventions"; repo fragments had it first
## (`t_repo_fragment_role_keys.nim`).
##
## What is checked, each against a real file read by the real reader:
##
## * top-level table keys (`url-prefix.name`, `url-prefix.url`,
##   `repo-set.name`, `project.default_remote`, `workspace.project`);
## * top-level string arrays (`member_repos[0]`, `member_sets[0]`);
## * keys in a nested object table (`certificates.gate_mode`,
##   `certificates.required_targets[0]`);
## * keys in array-of-table rows, in both spellings (`[[remote]]`,
##   `[[override]]`, `[[repo]]`, `apply_if = [{ … }]`);
## * a key two tables deep (`locking.route[0].backend`,
##   `locking.route[0].repos[0]`);
## * a repo fragment's `mainline` keeps its own explanation rather than the
##   generic one;
## * positive controls: the same manifests with quoted strings load, and a
##   non-string under `[extensions]` (preserved and ignored by the spec) does
##   not trip the rule.
##
## No mocks: real files in a temporary directory, the real readers.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

type Reader = proc (path: string) {.nimcall.}

proc readUrlPrefixFile(path: string) = discard readUrlPrefix(path)
proc readRepoSetFile(path: string) = discard readRepoSet(path)
proc readTemplateFile(path: string) = discard readTemplate(path)
proc readProjectFile(path: string) = discard readProjectManifest(path)
proc readVariantFile(path: string) = discard readVariantManifest(path)
proc readLockFile(path: string) = discard readLock(path)
proc readStateFile(path: string) = discard readWorkspaceLocal(path)
proc readOverridesFile(path: string) = discard readDevelopOverrides(path)
proc readConfigFile(path: string) = discard readReprobuildConfig(path)
proc readFragmentFile(path: string) = discard readRepoFragment(path)

proc fileAt(dir, name, text: string): string =
  result = dir / (name & ".toml")
  writeFile(result, text)

proc refusal(read: Reader; path: string): WorkspaceManifestParseError =
  ## The diagnostic `read` raises for `path`; fails the test when it reads
  ## cleanly.
  try:
    read(path)
  except WorkspaceManifestParseError as e:
    return e[]
  checkpoint("expected a refusal for " & path)
  fail()

const
  urlPrefixHead = "schema = \"reprobuild.workspace.url-prefix.v1\"\n"
  repoSetHead = "schema = \"reprobuild.workspace.repo-set.v1\"\n"
  templateHead = "schema = \"reprobuild.workspace.template.v1\"\n"
  projectHead = "schema = \"reprobuild.workspace.project.v1\"\n"
  variantHead = "schema = \"reprobuild.workspace.variant.v1\"\n"
  lockHead = "schema = \"reprobuild.workspace.lock.v1\"\n"
  stateHead = "schema = \"reprobuild.workspace.state.v1\"\n"
  overridesHead = "schema = \"reprobuild.workspace.develop-overrides.v1\"\n"
  configHead = "schema = \"reprobuild.config.v1\"\n"
  fragmentHead = "schema = \"reprobuild.workspace.repo.v2\"\n"

  lockRow = "[[repo]]\nname = \"a\"\npath = \"a\"\n" &
    "remote = \"https://example.invalid/a.git\"\n"

suite "a string key in any manifest refuses a non-string value":

  test "each wrong-typed value is refused at its key path":
    let dir = createTempDir("repro-string-keys-", "")
    defer: removeDir(dir)
    var n = 0
    for (read, text, keyPath) in [
        (Reader(readUrlPrefixFile), urlPrefixHead &
          "[url-prefix]\nname = 7\nurl = \"https://example.invalid/\"\n",
         "url-prefix.name"),
        (Reader(readUrlPrefixFile), urlPrefixHead &
          "[url-prefix]\nname = \"gh\"\nurl = false\n",
         "url-prefix.url"),
        (Reader(readRepoSetFile), repoSetHead &
          "member_repos = [true]\n[repo-set]\nname = \"s\"\n",
         "member_repos[0]"),
        (Reader(readRepoSetFile), repoSetHead &
          "member_repos = [\"a\"]\n[repo-set]\nname = 7\n",
         "repo-set.name"),
        (Reader(readTemplateFile), templateHead &
          "member_sets = [\"a\", 2]\n[template]\nname = \"t\"\n",
         "member_sets[1]"),
        (Reader(readProjectFile), projectHead &
          "[project]\nname = \"p\"\ndefault_remote = 7\n",
         "project.default_remote"),
        (Reader(readProjectFile), projectHead &
          "[project]\nname = \"p\"\n[certificates]\ngate_mode = true\n",
         "certificates.gate_mode"),
        (Reader(readProjectFile), projectHead &
          "[project]\nname = \"p\"\n[certificates]\n" &
          "required_targets = [\"t\", 1.5]\n",
         "certificates.required_targets[1]"),
        (Reader(readProjectFile), projectHead &
          "[project]\nname = \"p\"\n[[remote]]\nname = \"o\"\nfetch = false\n",
         "remote[0].fetch"),
        (Reader(readVariantFile), variantHead &
          "[variant]\nname = \"v\"\nbase = \"p\"\n" &
          "[[override]]\nfragment = \"a\"\nrevision = 1234\n",
         "override[0].revision"),
        (Reader(readLockFile), lockHead &
          "[lock]\nproject = \"p\"\ncreated_at = \"2026-11-22T00:00:00Z\"\n" &
          lockRow & "revision = 1234567\n",
         "repo[0].revision"),
        (Reader(readStateFile), stateHead &
          "[workspace]\nproject = 7\n",
         "workspace.project"),
        (Reader(readOverridesFile), overridesHead &
          "[[override]]\npackage = \"a\"\nlocal_path = \"a\"\n" &
          "state = \"active\"\ncreated_at = 20261122\n",
         "override[0].created_at"),
        (Reader(readConfigFile), configHead &
          "apply_if = [{ under = 1, config = \"c.toml\" }]\n",
         "apply_if[0].under"),
        (Reader(readConfigFile), configHead &
          "[locking]\nroute = [{ visibility = \"team\", backend = 7 }]\n",
         "locking.route[0].backend"),
        (Reader(readConfigFile), configHead &
          "[locking]\nroute = [{ visibility = \"team\", " &
          "backend = \"git-checkout\", repos = [\"a\", false] }]\n",
         "locking.route[0].repos[1]")]:
      inc n
      let file = fileAt(dir, "wrong-type-" & $n, text)
      let e = refusal(read, file)
      checkpoint(text)
      check e.path == file
      check e.keyPath == keyPath
      check "`" & keyPath & "` must be a string, not " in e.msg
      check file in e.msg

  test "the message says what was written":
    let dir = createTempDir("repro-string-keys-", "")
    defer: removeDir(dir)
    let e = refusal(readUrlPrefixFile, fileAt(dir, "x", urlPrefixHead &
      "[url-prefix]\nname = \"gh\"\nurl = false\n"))
    check "`url-prefix.url` must be a string, not `false`" in e.msg
    let f = refusal(readRepoSetFile, fileAt(dir, "y", repoSetHead &
      "member_repos = [\"a\"]\n[repo-set]\nname = 7\n"))
    check "`repo-set.name` must be a string, not an integer" in f.msg

  test "a repo fragment's mainline keeps its own explanation":
    let dir = createTempDir("repro-string-keys-", "")
    defer: removeDir(dir)
    let base = fragmentHead & "[repo]\nname = \"x\"\npath = \"x\"\n"
    let f = refusal(readFragmentFile, fileAt(dir, "f", base &
      "mainline = false\n"))
    check f.keyPath == "repo.mainline"
    check "`mainline` cannot be `false`" in f.msg
    let g = refusal(readFragmentFile, fileAt(dir, "g", base &
      "mainline = 7\n"))
    check g.keyPath == "repo.mainline"
    check "`mainline` must be a branch name, written as a string, not " &
      "an integer" in g.msg

  test "the same manifests with quoted strings load (positive control)":
    let dir = createTempDir("repro-string-keys-", "")
    defer: removeDir(dir)
    let up = readUrlPrefix(fileAt(dir, "up", urlPrefixHead &
      "[url-prefix]\nname = \"7\"\nurl = \"false\"\n" &
      "[extensions]\nfuture_flag = true\nfuture_count = 3\n"))
    check up.`url-prefix`.name == "7"
    check up.`url-prefix`.url == "false"
    check up.extensions.isPresent
    let rs = readRepoSet(fileAt(dir, "rs", repoSetHead &
      "member_repos = [\"true\"]\n[repo-set]\nname = \"7\"\n"))
    check rs.member_repos == @["true"]
    check rs.`repo-set`.name == "7"
    let pj = readProjectManifest(fileAt(dir, "pj", projectHead &
      "[project]\nname = \"p\"\ndefault_remote = \"7\"\n" &
      "[[remote]]\nname = \"o\"\nfetch = \"https://example.invalid/\"\n" &
      "[certificates]\ngate_mode = \"advisory\"\n" &
      "required_targets = [\"t\"]\n"))
    check pj.project.default_remote == some("7")
    check pj.remote[0].fetch == "https://example.invalid/"
    check pj.certificates.gate_mode == some("advisory")
    let vr = readVariantManifest(fileAt(dir, "vr", variantHead &
      "[variant]\nname = \"v\"\nbase = \"p\"\n" &
      "[[override]]\nfragment = \"a\"\nrevision = \"1234\"\n"))
    check vr.`override`[0].revision == some("1234")
    let lk = readLock(fileAt(dir, "lk", lockHead &
      "[lock]\nproject = \"p\"\ncreated_at = \"2026-11-22T00:00:00Z\"\n" &
      lockRow & "revision = \"1234567\"\n"))
    check lk.repo[0].revision == "1234567"
    let cfg = readReprobuildConfig(fileAt(dir, "cfg", configHead &
      "apply_if = [{ under = \"~/w/\", config = \"c.toml\" }]\n" &
      "[locking]\nroute = [{ visibility = \"team\", " &
      "backend = \"git-checkout\", repos = [\"a\"] }]\n"))
    check cfg.locking.route[0].backend == "git-checkout"
    check cfg.locking.route[0].repos == @["a"]
    check cfg.apply_if[0].under == "~/w/"
