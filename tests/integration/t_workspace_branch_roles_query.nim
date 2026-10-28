## `repro workspace branch-roles` through the real `repro` binary
## (Workspace-Branch-Roles.md §4.5, with the reporting vocabulary of §4.4).
##
## The query prints, per selected repo, what every branch role resolves to
## and through which chain — or one role's column with `--to=<role>` or a
## shorthand — in text and `--json`, fetching nothing. This test pins each of
## those clauses against one workspace:
##
##   * `repro-workspace.toml` (`settings.v1`) declares the root repo's own
##     roles in `[workspace]`, a `product` profile (`main` / `agents` /
##     `release`), a `spec` profile (`latest`) and a custom role `partner`
##     falling back to `staging`;
##   * `core` follows `product`; `docs` follows `spec`; `tool` follows
##     `product` but overrides its mainline (`trunk`), declares its unstable
##     tier ABSENT (`unstable = false`) and declares `partner` itself.
##
## Legs:
##   1. every role, text: one block per repo, a fallback shown with its chain
##      and a direct declaration without one; the root repo listed first;
##   2. every role, JSON: `role` / `resolvedRole` / `roleBranch` /
##      `fallbackPath` (EMPTY for a direct declaration, §4.4) / `declaredBy`,
##      the custom role among `roleNames`, the root object present;
##   3. one role: `--unstable` prints exactly §4.4's text form, and every
##      shorthand is byte-identical to its `--to=` spelling, text and JSON;
##      a custom role is reached through `--to=` only;
##   4. usage errors exit 2 with nothing on stdout: an undeclared role, two
##      different roles, a sweep flag (`--rebase`), a selector with no value,
##      a repo named where a project belongs; repeating the SAME role is
##      accepted;
##   5. selectors are `repro sync`'s: `--only=docs` lists only `docs`, and a
##      selected set omits the root repo;
##   6. nothing is fetched: `core` is a real clone whose remote gained a
##      branch after the clone; every ref in the clone, and the absence of
##      `FETCH_HEAD`, are identical before and after every leg. `core`
##      declares (through its profile) a `stable = "release"` that NO remote
##      has, and the query still answers `release` — roles resolve from
##      declarations, never from what a remote advertises (§2.2).
##
## No mocks: real git repositories behind `file://` remotes and the real
## `repro` binary as a subprocess. Skip rule: `git` missing from PATH.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

type RunResult = tuple[code: int; stdout, stderr: string]

proc runRepro(args: openArray[string]): RunResult =
  ## The real binary's exit code, stdout and stderr, read separately. The
  ## fixture's settings file must be found by discovery, not by an inherited
  ## `REPRO_WORKSPACE_CONFIG` pointing elsewhere.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(reproBinary(), args = @args, env = env, options = {})
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc requireOk(command: string): string {.discardable.} =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1
  res.output

proc gitIdentity(gitBin, path: string) =
  requireOk(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  requireOk(q(gitBin) & " -C " & q(path) & " config user.name Tester")

proc seedBare(gitBin, scratch, barePath: string; branches: openArray[string]) =
  ## A bare repository with one commit, published on every name in
  ## `branches` (the first is the initial branch).
  let work = scratch / ("seed-" & extractFilename(barePath))
  requireOk(q(gitBin) & " init -q -b " & branches[0] & " " & q(work))
  gitIdentity(gitBin, work)
  writeFile(work / "README", extractFilename(barePath) & "\n")
  requireOk(q(gitBin) & " -C " & q(work) & " add -A")
  requireOk(q(gitBin) & " -C " & q(work) & " commit -q -m fixture")
  for b in branches[1 .. ^1]:
    requireOk(q(gitBin) & " -C " & q(work) & " branch " & b)
  requireOk(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))
  for b in branches[1 .. ^1]:
    requireOk(q(gitBin) & " -C " & q(work) & " push -q " & q(barePath) &
      " " & b)

const
  settingsToml = "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[workspace]\nmainline = \"main\"\nunstable = \"agents\"\n\n" &
    "[profiles.product]\nmainline = \"main\"\nunstable = \"agents\"\n" &
    "stable = \"release\"\n\n" &
    "[profiles.spec]\nmainline = \"latest\"\n\n" &
    "[branch-roles.partner]\nfallback = \"staging\"\n"

proc fragmentToml(name, keys: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nurl_prefix = \"acme\"\n" & keys & "\n"

proc refsSnapshot(gitBin, repo: string): string =
  ## Every ref the clone holds, with its object id, plus whether a fetch ever
  ## left a `FETCH_HEAD` behind.
  requireOk(q(gitBin) & " -C " & q(repo) &
    " for-each-ref --format='%(refname) %(objectname)'") &
    "FETCH_HEAD present: " & $fileExists(repo / ".git" / "FETCH_HEAD")

proc findByName(nodes: JsonNode; key, name: string): JsonNode =
  result = newJNull()
  for n in nodes:
    if n[key].getStr() == name:
      return n

proc roleOf(entry: JsonNode; role: string): JsonNode =
  findByName(entry["roles"], "role", role)

suite "repro workspace branch-roles":

  test "t_workspace_branch_roles_query":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the member repositories are real " &
        "repositories behind file:// remotes")
    else:
      let scratch = createTempDir("repro-branch-roles-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBare(gitBin, scratch, remotes / "core", ["main", "agents"])
      seedBare(gitBin, scratch, remotes / "docs", ["latest"])
      seedBare(gitBin, scratch, remotes / "tool", ["trunk", "partner-x"])

      let root = scratch / "ws"
      for d in ["projects", "repos", "url-prefixes", ".repro"]:
        createDir(root / d)
      writeFile(root / "repro-workspace.toml", settingsToml)
      writeFile(root / "projects" / "demo.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "member_repos = [\"core\", \"docs\", \"tool\"]\n\n" &
        "[project]\nname = \"demo\"\n")
      writeFile(root / "url-prefixes" / "acme.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n[url-prefix]\n" &
        "name = \"acme\"\nurl = \"" & fileUrl(remotes) & "\"\n")
      writeFile(root / "repos" / "core.toml",
        fragmentToml("core", "profile = \"product\""))
      writeFile(root / "repos" / "docs.toml",
        fragmentToml("docs", "profile = \"spec\""))
      writeFile(root / "repos" / "tool.toml",
        fragmentToml("tool", "profile = \"product\"\nmainline = \"trunk\"\n" &
          "unstable = false\n\n[repo.branch-roles]\npartner = \"partner-x\""))
      writeFile(root / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\nprojects = [\"demo\"]\n")

      # `core` is a real clone. After it was cloned the remote gained a
      # branch; a query that fetched would bring it in.
      requireOk(q(gitBin) & " clone -q " & q(fileUrl(remotes / "core")) &
        " " & q(root / "core"))
      block:
        let work = scratch / "seed-core"
        requireOk(q(gitBin) & " -C " & q(work) & " branch fetched-would-see")
        requireOk(q(gitBin) & " -C " & q(work) & " push -q " &
          q(remotes / "core") & " fetched-would-see")
      let refsBefore = refsSnapshot(gitBin, root / "core")
      check "fetched-would-see" notin refsBefore
      check "FETCH_HEAD present: false" in refsBefore

      proc roles(extra: openArray[string]): RunResult =
        var argv = @["workspace", "branch-roles", "--workspace-root=" & root]
        argv.add(@extra)
        result = runRepro(argv)
        checkpoint("branch-roles " & extra.join(" ") & " exit=" &
          $result.code & "\nstdout:\n" & result.stdout & "\nstderr:\n" &
          result.stderr)

      # ---- 1. every role, text ---------------------------------------------
      let allText = roles([])
      check allText.code == 0
      let blocks = allText.stdout.strip().split("\n\n")
      check blocks.len == 4
      if blocks.len == 4:
        check blocks[0] ==
          "(root)\n" &
          "  mainline    main\n" &
          "  unstable    agents\n" &
          "  staging     main    (staging → mainline)\n" &
          "  stable      main    (stable → mainline)\n" &
          "  production  main    (production → stable → mainline)\n" &
          "  lts         main    (lts → stable → mainline)\n" &
          "  partner     main    (partner → staging → mainline)"
        check blocks[1] ==
          "core  (profile product)\n" &
          "  mainline    main\n" &
          "  unstable    agents\n" &
          "  staging     main     (staging → mainline)\n" &
          "  stable      release\n" &
          "  production  release  (production → stable)\n" &
          "  lts         release  (lts → stable)\n" &
          "  partner     main     (partner → staging → mainline)"
        check blocks[2].startsWith("docs  (profile spec)\n  mainline    latest\n" &
          "  unstable    latest  (unstable → mainline)\n")
        check blocks[3] ==
          "tool  (profile product)\n" &
          "  mainline    trunk\n" &
          "  unstable    trunk      (unstable → mainline)\n" &
          "  staging     trunk      (staging → mainline)\n" &
          "  stable      release\n" &
          "  production  release    (production → stable)\n" &
          "  lts         release    (lts → stable)\n" &
          "  partner     partner-x"

      # ---- 2. every role, JSON ---------------------------------------------
      let allJson = roles(["--json"])
      check allJson.code == 0
      let doc = parseJson(allJson.stdout)
      check doc["role"].kind == JNull
      check doc["roleNames"] == %["mainline", "unstable", "staging", "stable",
        "production", "lts", "partner"]
      check doc["root"].kind == JObject
      check doc["root"]["path"].getStr() == "."
      check doc["root"].roleOf("unstable")["roleBranch"].getStr() == "agents"
      check doc["root"].roleOf("unstable")["declaredBy"].getStr() ==
        "workspace"
      var names: seq[string]
      for r in doc["repos"]:
        names.add(r["name"].getStr())
      check names == @["core", "docs", "tool"]
      let core = doc["repos"].findByName("name", "core")
      let coreUnstable = core.roleOf("unstable")
      check coreUnstable["roleBranch"].getStr() == "agents"
      check coreUnstable["resolvedRole"].getStr() == "unstable"
      check coreUnstable["fallbackPath"] == newJArray()
      check coreUnstable["declaredBy"].getStr() == "profile"
      check coreUnstable["profile"].getStr() == "product"
      # Declared, and on no remote at all: still the answer.
      check core.roleOf("stable")["roleBranch"].getStr() == "release"
      let docsProduction = doc["repos"].findByName("name", "docs")
        .roleOf("production")
      check docsProduction["roleBranch"].getStr() == "latest"
      check docsProduction["resolvedRole"].getStr() == "mainline"
      check docsProduction["fallbackPath"] ==
        %["production", "stable", "mainline"]
      let tool = doc["repos"].findByName("name", "tool")
      check tool.roleOf("unstable")["roleBranch"].getStr() == "trunk"
      check tool.roleOf("unstable")["fallbackPath"] == %["unstable", "mainline"]
      check tool.roleOf("unstable")["declaredBy"].getStr() == "fragment"
      check tool.roleOf("partner")["roleBranch"].getStr() == "partner-x"

      # ---- 3. one role -------------------------------------------------------
      let unstable = roles(["--unstable"])
      check unstable.code == 0
      check unstable.stdout ==
        "(root)  agents (unstable)\n" &
        "core    agents (unstable)\n" &
        "docs    latest (unstable → mainline)\n" &
        "tool    trunk (unstable → mainline)\n"
      for role in ["mainline", "unstable", "staging", "stable", "production",
                   "lts"]:
        for extra in [newSeq[string](), @["--json"]]:
          let shorthand = roles(@["--" & role] & extra)
          let spelled = roles(@["--to=" & role] & extra)
          check shorthand.code == 0
          check shorthand.stdout.len > 0
          check shorthand.stdout == spelled.stdout
      let unstableJson = parseJson(roles(["--unstable", "--json"]).stdout)
      check unstableJson["role"].getStr() == "unstable"
      check unstableJson["roleNames"] == %["unstable"]
      for r in unstableJson["repos"]:
        check r["roles"].len == 1
      let partner = roles(["--to=partner"])
      check partner.code == 0
      check "tool    partner-x (partner)\n" in partner.stdout
      check "core    main (partner → staging → mainline)\n" in partner.stdout

      # ---- 4. usage errors ---------------------------------------------------
      let undeclared = roles(["--to=beta"])
      check undeclared.code == 2
      check undeclared.stdout.len == 0
      check "'beta'" in undeclared.stderr
      check "partner" in undeclared.stderr
      let twoRoles = roles(["--unstable", "--stable"])
      check twoRoles.code == 2
      check twoRoles.stdout.len == 0
      check "mutually exclusive" in twoRoles.stderr
      let sweepFlag = roles(["--rebase"])
      check sweepFlag.code == 2
      check "--rebase" in sweepFlag.stderr
      # The selector parser is shared with sync and raises plain errors; on
      # this verb they are usage errors all the same.
      let selectorNoValue = roles(["--only"])
      check selectorNoValue.code == 2
      check selectorNoValue.stdout.len == 0
      check "--only requires a value" in selectorNoValue.stderr
      let repoAsProject = roles(["core"])
      check repoAsProject.code == 2
      check repoAsProject.stdout.len == 0
      check "--only=core" in repoAsProject.stderr
      # The shared project resolver must keep this query's own command in
      # the error body and remedy, even though sync uses the same resolver.
      let unknownProject = roles(["nosuchproject"])
      check unknownProject.code != 0
      check unknownProject.stdout.len == 0
      check "unknown project 'nosuchproject' passed to " &
        "`repro workspace branch-roles`" in unknownProject.stderr
      check "run `repro workspace branch-roles` with no project" in
        unknownProject.stderr
      check "--only / --filter" in unknownProject.stderr
      check "repro workspace sync" notin unknownProject.stderr
      check "repro sync" notin unknownProject.stderr
      check "repro sync" notin repoAsProject.stderr
      check "`repro workspace branch-roles --only=core`" in repoAsProject.stderr
      let sameRoleTwice = roles(["--to=unstable", "--unstable"])
      check sameRoleTwice.code == 0
      check sameRoleTwice.stdout == unstable.stdout

      # ---- 5. selectors --------------------------------------------------------
      let onlyDocs = roles(["--only=docs", "--stable", "--json"])
      check onlyDocs.code == 0
      let onlyDoc = parseJson(onlyDocs.stdout)
      check onlyDoc["root"].kind == JNull
      check onlyDoc["repos"].len == 1
      if onlyDoc["repos"].len == 1:
        check onlyDoc["repos"][0]["name"].getStr() == "docs"
      check roles(["--only=docs", "--stable"]).stdout ==
        "docs  latest (stable → mainline)\n"

      # Without recorded membership, the positional is the initial resolution
      # target rather than a filter. This path must not borrow sync's name.
      removeFile(root / ".repro" / "workspace.toml")
      let unknownUnrecorded = roles(["nosuchproject"])
      check unknownUnrecorded.code != 0
      check unknownUnrecorded.stdout.len == 0
      check "nosuchproject" in unknownUnrecorded.stderr
      check "repro workspace sync" notin unknownUnrecorded.stderr
      check "repro sync" notin unknownUnrecorded.stderr

      # ---- 6. nothing was fetched ----------------------------------------------
      check refsSnapshot(gitBin, root / "core") == refsBefore
