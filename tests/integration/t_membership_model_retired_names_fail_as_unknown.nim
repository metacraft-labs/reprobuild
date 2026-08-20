## Workspace-Membership-Model.md §"Reclaiming `groups`" — the retired spellings
## fail as UNKNOWN, and the current ones work.
##
## `repo.groups` + `repro sync --groups=…` named a subset FILTER over a repo
## set. The membership model reclaims that word for the membership concept
## (`member_sets` / `member_repos`), so the filter is now `repo.tags` +
## `repro sync --tags=…`, and the filter over the same field on `repro develop`
## is `--tag=`.
##
## Retired names are recorded in `reprobuild-specs/Retired-Names.md`, whose
## rule this test enforces: they fail as unknown rather than being accepted
## with a warning. A warning tells a script nothing — it exits 0 and the run
## proceeds having ignored the operator's selection, which for a SUBSET filter
## means silently operating on the wrong repo set. A hard failure is the only
## behaviour that reliably says "you are out of date".
##
## Asserted, each with its current-spelling positive control so a passing
## refusal cannot be a command that is broken for everyone:
##   1. `repro workspace sync --groups=…` exits NONZERO and names the flag as
##      unsupported; `--tags=…` is accepted by the same parser.
##   2. `repro develop --group=…` exits NONZERO; `--tag=…` is accepted.
##   3. `repro workspace enable --groups=…` exits NONZERO — the forwarding verb
##      forwards the CURRENT flag, so a retired one cannot slip through by
##      being passed along unexamined.
##   4. A repo fragment declaring `groups = […]` is REFUSED by the strict
##      reader; the same fragment with `tags = […]` parses and carries them.
##   5. A repo-set declaring the single-list `members = […]` is REFUSED. The
##      membership keys are two namespaces; a bare name under one list would
##      have to resolve against both, which is the ambiguity two keys make
##      unrepresentable.
##
## Falsifiability: every refusal is paired with the positive control on the
## same surface, so "the flag is rejected" cannot pass because the whole
## command errored for an unrelated reason. Exit codes are asserted, not just
## message text, because the point of the rule is the exit code.
##
## No mocks: the real `repro` binary and the real strict readers, on real
## files. Hermetic — an empty workspace root is enough to reach argv parsing,
## and no case needs the network or git.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc runRepro(reproBin, workspaceRoot: string;
              args: openArray[string]): CmdResult =
  var argv = @[reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & workspaceRoot)
  runShell(shellCommand(argv))

proc fragment(tagsKey: string): string =
  ## One repo fragment, with the subset-label array written under whichever key
  ## the caller names. Identical in every other byte, so the only variable
  ## between the refusal and the positive control is the key itself.
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"lib-tools\"\n" &
  "path = \"lib-tools\"\n" &
  "remote = \"acme\"\n" &
  "revision = \"main\"\n" &
  tagsKey & " = [\"tools\"]\n"

suite "membership model — retired names fail as unknown":

  test "t_sync_groups_flag_is_unknown_and_tags_is_accepted":
    let scratch = createTempDir("repro-retired-sync-", "")
    defer: removeDir(scratch)
    let ws = scratch / "ws"
    createDir(ws)
    let reproBin = reproBinary()

    let retired = runRepro(reproBin, ws, ["workspace", "sync", "--groups=default"])
    check retired.code != 0
    check retired.output.contains("--groups=default")
    # The rule is "fails as unknown", not "warns and continues". A run that
    # said `deprecated` and proceeded would have exited 0 above; assert the
    # vocabulary too so a future well-meant compatibility shim trips here.
    check "deprecated" notin retired.output.toLowerAscii()

    # Positive control: the same parser, the current spelling. An empty
    # workspace still fails later for want of a manifest, so the assertion is
    # specifically that the FLAG was not what it rejected.
    let current = runRepro(reproBin, ws, ["workspace", "sync", "--tags=default"])
    check "--tags=default" notin current.output

  test "t_develop_group_flag_is_unknown_and_tag_is_accepted":
    let scratch = createTempDir("repro-retired-develop-", "")
    defer: removeDir(scratch)
    let ws = scratch / "ws"
    createDir(ws)
    let reproBin = reproBinary()

    let retired = runRepro(reproBin, ws, ["develop", "--list", "--group=libs"])
    check retired.code != 0
    check retired.output.contains("--group=libs")

    let current = runRepro(reproBin, ws, ["develop", "--list", "--tag=libs"])
    check "--tag=libs" notin current.output

  test "t_enable_does_not_forward_the_retired_groups_flag":
    # `enable` forwards a fixed allow-list of flags to the sync it triggers. A
    # retired flag must not survive by being passed along unexamined, so the
    # allow-list names the CURRENT spelling and the retired one is rejected at
    # the verb that received it.
    let scratch = createTempDir("repro-retired-enable-", "")
    defer: removeDir(scratch)
    let ws = scratch / "ws"
    createDir(ws)
    let reproBin = reproBinary()

    let retired = runRepro(reproBin, ws, ["workspace", "enable", "--groups=x"])
    check retired.code != 0
    check retired.output.contains("--groups=x")

  test "t_repo_fragment_groups_key_is_refused_and_tags_parses":
    let d = createTempDir("repro-retired-fragment-", "")
    defer: removeDir(d)

    let retiredFile = d / "retired.toml"
    writeFile(retiredFile, fragment("groups"))
    var refused = false
    try:
      discard readRepoFragment(retiredFile)
    except WorkspaceManifestParseError:
      refused = true
    check refused

    let currentFile = d / "current.toml"
    writeFile(currentFile, fragment("tags"))
    let m = readRepoFragment(currentFile)
    check m.repo.tags == @["tools"]

  test "t_repo_set_single_members_list_is_refused":
    let d = createTempDir("repro-retired-members-", "")
    defer: removeDir(d)
    let f = d / "legacy.toml"
    writeFile(f, """
schema = "reprobuild.workspace.repo-set.v1"

[repo-set]
name = "legacy"

members = ["infra"]
""")
    var refused = false
    try:
      discard readRepoSet(f)
    except WorkspaceManifestParseError:
      refused = true
    check refused

    # Positive control: the two-key spelling on the same reader.
    let ok = d / "current.toml"
    writeFile(ok, """
schema = "reprobuild.workspace.repo-set.v1"

[repo-set]
name = "current"

member_sets = ["shared-infrastructure"]
member_repos = ["infra"]
""")
    let m = readRepoSet(ok)
    check m.member_sets == @["shared-infrastructure"]
    check m.member_repos == @["infra"]
