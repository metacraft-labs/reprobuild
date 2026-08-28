## A refusal that names a command owes the operator a command that RUNS.
##
## Both halves of this test were hit for real while unblocking a stuck
## workspace, and both cost hours, because the tool answered a refusal with an
## instruction that could not be carried out from where the operator stood.
##
## Case A — the workspace-lock integrity refusal named the WRONG lock verb.
##   A team repo's locked revision vanished (an upstream force-push, then a
##   fresh clone), so the pre-push gate refused with
##   ``locked-integrity-mismatch`` and told the operator to run
##   ``repro lock refresh``. That is the SOLVED-GRAPH lock verb: it re-pins the
##   committed ``reprobuild.solved-graph-lock.v2`` ``repro.lock`` from a
##   recipe's solver inputs. Run at a workspace root it answers "no solver
##   inputs found …" and exits non-zero. The artifact this refusal is about is
##   the WORKSPACE lock — ``locks/<project>/<repo>/<sha>.toml`` inside the
##   tier's backend — and the verb that re-pins THAT is
##   ``repro workspace lock``. The two lock artifacts are genuinely distinct,
##   so naming the wrong one is not a typo: it sends the operator to a command
##   that cannot succeed no matter how many times it is retried.
##
## Case C — the immutable-record refusal named no command at all, and the
##   gate wrapped it in the one command guaranteed not to help.
##   A published lock record is keyed by (trigger repo, trigger sha) and is
##   immutable; publication is additions-only. When the trigger repo's HEAD has
##   not moved but a sibling's has, the writer recomputes the same key, sees
##   different sibling coordinates, and refuses with
##
##     immutable lock record already exists at 'locks/<p>/<t>/<sha>.toml' with
##     different repository coordinates (changed paths: …); keep the existing
##     record and create a lock anchored by the commit that changed
##
##   "create a lock anchored by the commit that changed" is a correct
##   description of the repair and not something an operator can type. The
##   pre-push gate then discarded even that and rendered its own remediation:
##   "investigate the lock writer error and re-run 'repro check'" — naming the
##   invocation that had just refused. Between them the two messages named no
##   way forward, and the coordinate cannot be rewritten, so the workspace
##   stayed refused.
##
##   The repair is expressible: keep the published record, and anchor the new
##   state at a repo whose commit actually moved — ``repro workspace lock
##   --workspace-root=<root> --trigger-repo=<name>``. Its coordinate is free
##   precisely because that repo moved. This case asserts it the same way case
##   A does: parse the command out of the gate's own remediation, run it
##   verbatim from the pushed repo, require exit 0, and require the refusal to
##   be gone.
##
## Case B — the repair verb could not run in its documented form.
##   ``repro workspace migrate-locks --dry-run`` — the exact invocation the
##   publisher's refusal prints, and the exact invocation ``repro workspace
##   --help`` documents — seeded ``tpmUnspecified`` as its tool-provisioning
##   mode. ``resolveGitTool`` rejects that outright ("no provisioning mode was
##   selected before resolving git; callers must parse --tool-provisioning
##   before invoking resolveGitTool"), so the verb exited 1 before doing any
##   work unless ``--tool-provisioning=path`` was passed — a flag neither the
##   help text nor the remedy mentions. Every other workspace verb seeds
##   ``tpmPathOnly`` and lets the flag override it; this one now does too.
##
## What is asserted, and why it is not a string check
## --------------------------------------------------
## A test that merely asserts the remedy CONTAINS "repro workspace lock" is
## satisfied by any string, including one that names a verb that does not
## exist or cannot run here. So case A instead pins the property that matters:
##
##   1. parse every ``\`…\```-quoted command OUT of the refusal's own
##      ``remediation`` field — whatever it happens to say;
##   2. run each ``repro …`` command among them VERBATIM, from the directory
##      the operator is standing in when the gate speaks (the pushed repo, not
##      the workspace root — the pre-push hook runs inside the repo);
##   3. require it to exit 0;
##   4. re-run the gate and require the refusal to be GONE.
##
## (4) is the real assertion: the named command must actually clear the
## failure it was offered for. Substituting any other verb — including the
## historical ``repro lock refresh`` — fails at (3) or (4).
##
## Case A also pins the SHARPENED diagnosis. "the content no longer matches
## the recorded integrity" and "the locked revision is not present" are
## different failures with different repairs: content changing under a
## still-reachable revision means the record or the tree was rewritten;
## a revision that is simply GONE is what a force-push leaves behind. The
## refusal used to print the first while its evidence said the second. The
## evidence now carries a machine-readable ``cause=`` token and the
## remediation prose matches it.
##
## Hermetic: fresh tempdir; only local ``git init`` / ``git init --bare``
## repos; no network. The system/dotfiles/VCS-private configuration layers are
## silenced with env overrides. Skip: ``git`` missing or ``./build/bin/repro``
## absent. No mocks: the real ``repro`` binary, the real git-checkout lock
## backend, the real pre-push gate.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_workspace_manifests

const reproBinary = "./build/bin/repro"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc gitConfig(gitBin, repo: string) =
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.name \"Remedy Tester\"")

proc quotedSpans(message: string; delimiter: char): seq[string] =
  ## Every ``<delimiter>…<delimiter>``-quoted span in a message, in order.
  ## The refusal texts quote copy-pasteable commands in backticks and the
  ## publisher quotes them in single quotes; both are parsed the same way.
  var i = 0
  while true:
    let a = message.find(delimiter, i)
    if a < 0: break
    let b = message.find(delimiter, a + 1)
    if b < 0: break
    result.add(message[(a + 1) ..< b])
    i = b + 1

proc namedReproCommands(message: string): seq[string] =
  ## The ``repro …`` invocations a message tells the operator to run.
  for span in quotedSpans(message, '`') & quotedSpans(message, '\''):
    let cmd = span.strip()
    if cmd.startsWith("repro ") and cmd notin result:
      result.add(cmd)

proc silenceLayers(scratch: string) =
  putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")

proc unsilenceLayers() =
  delEnv("REPROBUILD_SYSTEM_CONFIG")
  delEnv("REPROBUILD_USER_CONFIG")
  delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc projectToml(coreUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc readReport(ws: string): JsonNode =
  parseFile(ws / ".repro" / "build" / "reports" / "check-report.json")

proc integrityFailure(report: JsonNode): JsonNode =
  for f in report["failures"]:
    if f["property"].getStr() == "locked-integrity-mismatch":
      return f
  return nil

suite "a refusal names a command that runs where the operator is standing":

  test "t_lock_failure_remedies_name_a_runnable_command":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let reproAbs = absolutePath(reproBinary)
      let scratch = createTempDir("remedy-runs-", "")
      defer: removeDir(scratch)
      silenceLayers(scratch)
      defer: unsilenceLayers()

      # ================================================================
      # Case A — the workspace-lock integrity refusal
      # ================================================================

      # A manifest-present workspace with ONE repo (``core``) routed to a
      # separate team git-checkout backend, so the locked record lives only in
      # that backend and the refusal is the ROUTED (tier=team) one.
      let coreOrigin = scratch / "origin-core.git"
      discard requireGit(q(gitBin) & " init -q --bare -b main " & q(coreOrigin))

      let seedClone = scratch / "seed-core"
      discard requireGit(q(gitBin) & " init -q -b main " & q(seedClone))
      gitConfig(gitBin, seedClone)
      writeFile(seedClone / "seed.txt", "seed\n")
      discard requireGit(q(gitBin) & " -C " & q(seedClone) & " add seed.txt")
      discard requireGit(q(gitBin) & " -C " & q(seedClone) & " commit -qm seed")
      discard requireGit(q(gitBin) & " -C " & q(seedClone) &
        " remote add origin " & q(coreOrigin))
      discard requireGit(q(gitBin) & " -C " & q(seedClone) &
        " push -q origin main")

      let ws = scratch / "workspace"
      createDir(ws)
      createDir(ws / "projects")
      createDir(ws / "repos")
      writeFile(ws / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin))
      writeFile(ws / "repos" / "core.toml",
        repoFragment("core", "core-origin"))

      proc cloneCore() =
        discard requireGit(q(gitBin) & " clone -q " &
          q("file://" & coreOrigin) & " " & q(ws / "core"))
        gitConfig(gitBin, ws / "core")

      cloneCore()
      writeWorkspaceBranch(ws, project = "mix", branch = "main")

      let teamManifest = ws / "manifests-team"
      discard requireGit(q(gitBin) & " init -q -b main " & q(teamManifest))
      gitConfig(gitBin, teamManifest)
      writeFile(teamManifest / "seed.txt", "seed\n")
      discard requireGit(q(gitBin) & " -C " & q(teamManifest) & " add seed.txt")
      discard requireGit(q(gitBin) & " -C " & q(teamManifest) &
        " commit -qm seed")

      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [" &
        "{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \"manifests-team\", repos = [\"core\"] }]\n")

      # Lock at the ORIGINAL revision — the record the incident's lock held.
      let lockRes = run(reproAbs & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0
      let lockedSha = requireGit(q(gitBin) & " -C " & q(ws / "core") &
        " rev-parse HEAD").strip()
      check fileExists(teamManifest / "locks" / "mix" / "core" /
        (lockedSha & ".toml"))

      # The incident, reproduced: upstream REWRITES history (a force-push), and
      # the workspace's checkout is replaced by a fresh clone. The locked
      # revision is now absent from the checkout's object store entirely — it
      # is not "content that changed", it is a revision that is GONE.
      let rewrite = scratch / "rewrite-core"
      discard requireGit(q(gitBin) & " clone -q " &
        q("file://" & coreOrigin) & " " & q(rewrite))
      gitConfig(gitBin, rewrite)
      writeFile(rewrite / "seed.txt", "rewritten\n")
      discard requireGit(q(gitBin) & " -C " & q(rewrite) & " add seed.txt")
      discard requireGit(q(gitBin) & " -C " & q(rewrite) &
        " commit -q --amend -m seed")
      discard requireGit(q(gitBin) & " -C " & q(rewrite) &
        " push -q --force origin main")
      removeDir(ws / "core")
      cloneCore()
      let liveSha = requireGit(q(gitBin) & " -C " & q(ws / "core") &
        " rev-parse HEAD").strip()
      check liveSha != lockedSha
      # Genuinely unreachable, not merely un-referenced.
      check run(q(gitBin) & " -C " & q(ws / "core") &
        " rev-parse --verify --quiet " & q(lockedSha & "^{commit}")).code != 0

      let refsFile = scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/main " & liveSha &
        " refs/heads/main 0000000000000000000000000000000000000000\n")

      proc gate(): tuple[code: int; output: string] =
        run(reproAbs & " check --mode=pre-push --write-report" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws / "core") &
          " --pushed-refs=" & q(refsFile) & " --json")

      let refusal = gate()
      checkpoint("gate output: " & refusal.output)
      check refusal.code == 2
      let failure = integrityFailure(readReport(ws))
      check failure != nil
      let remediation = failure["remediation"].getStr()
      let evidence = failure["evidence"].getStr()
      checkpoint("remediation: " & remediation)
      checkpoint("evidence: " & evidence)

      # ---- the SHARPENED diagnosis --------------------------------------
      # The revision is gone; the refusal must say so and must not assert the
      # different, unobserved claim that the content changed underneath it.
      check evidence.contains("cause=locked-revision-unreachable")
      check evidence.contains("tier=team")
      check evidence.contains("backend=git-checkout")
      check remediation.contains(lockedSha)
      check not remediation.contains("no longer matches")

      # ---- the remedy is a command, and the command runs -----------------
      let commands = namedReproCommands(remediation)
      checkpoint("commands named: " & commands.join(" | "))
      check commands.len >= 1
      for cmd in commands:
        # Verbatim, from the directory the pre-push hook actually runs in —
        # the pushed REPO, not the workspace root. A remedy that only works
        # after the operator guesses a `cd` is not a remedy.
        let res = run(reproAbs & cmd["repro".len .. ^1], cwd = ws / "core")
        checkpoint("ran `" & cmd & "` -> exit " & $res.code & "\n" & res.output)
        check res.code == 0
        # The historical wrong answer failed exactly here.
        check not res.output.contains("no solver inputs found")

      # ---- and running it CLEARS the refusal it was offered for ----------
      let after = gate()
      checkpoint("gate after remedy: " & after.output)
      check after.code == 0
      check integrityFailure(readReport(ws)) == nil

      # ================================================================
      # Case B — `repro workspace migrate-locks --dry-run`, as documented
      # ================================================================
      # The publisher's refusal prints exactly this invocation, and
      # `repro workspace --help` documents exactly this invocation. Neither
      # mentions `--tool-provisioning`, so this is the form that has to work.
      let ws2 = scratch / "migrate-workspace"
      let store = ws2 / ".repro" / "manifests"
      createDir(parentDir(store))
      discard requireGit(q(gitBin) & " init -q --bare -b main " &
        q(scratch / "manifest-origin.git"))
      discard requireGit(q(gitBin) & " clone -q " &
        q(scratch / "manifest-origin.git") & " " & q(store))
      gitConfig(gitBin, store)
      writeFile(store / "README.md", "manifest store\n")
      discard requireGit(q(gitBin) & " -C " & q(store) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(store) & " commit -qm seed")
      discard requireGit(q(gitBin) & " -C " & q(store) & " push -q origin main")

      # A record at the raw joined path the old writer left behind: a repo
      # whose NAME carries a slash landed at depth 5 where the format is 4.
      let strayRel = "locks/mix/stripe/sync-engine/" &
        "1111111111111111111111111111111111111111.toml"
      createDir(store / "locks" / "mix" / "stripe" / "sync-engine")
      writeFile(store / strayRel.replace('/', DirSep),
        "[[repo]]\nname = \"stripe/sync-engine\"\n" &
        "path = \"stripe-sync-engine\"\n" &
        "revision = \"1111111111111111111111111111111111111111\"\n")
      discard requireGit(q(gitBin) & " -C " & q(store) & " add -f -A -- locks")
      discard requireGit(q(gitBin) & " -C " & q(store) & " commit -qm stray")

      let dryRun = run(reproAbs & " workspace migrate-locks --dry-run",
        cwd = ws2)
      checkpoint("migrate-locks --dry-run: exit " & $dryRun.code & "\n" &
        dryRun.output)
      # It ran, rather than refusing to resolve git before doing any work.
      check not dryRun.output.contains("tool resolution failed")
      check not dryRun.output.contains("--tool-provisioning")
      check dryRun.code == 0
      check dryRun.output.contains("to relocate")
      check dryRun.output.contains(strayRel)
      # A dry run is read-only: the record is still where it was.
      check fileExists(store / strayRel.replace('/', DirSep))

      # ================================================================
      # Case C — the immutable-record refusal
      # ================================================================
      # A workspace with TWO declared repos and a default (unrouted)
      # ``.repro/manifests`` git-checkout store, so the refusal is the
      # trigger-keyed partition one.
      let ws3 = scratch / "immutable-workspace"
      createDir(ws3 / "projects")
      createDir(ws3 / "repos")

      proc seedRepo3(name, seed: string) =
        let origin = scratch / ("c-origin-" & name & ".git")
        discard requireGit(q(gitBin) & " init -q --bare -b main " & q(origin))
        discard requireGit(q(gitBin) & " clone -q " & q("file://" & origin) &
          " " & q(ws3 / name))
        gitConfig(gitBin, ws3 / name)
        writeFile(ws3 / name / "seed.txt", seed)
        discard requireGit(q(gitBin) & " -C " & q(ws3 / name) & " add -A")
        discard requireGit(q(gitBin) & " -C " & q(ws3 / name) &
          " commit -qm " & q("seed " & name))
        discard requireGit(q(gitBin) & " -C " & q(ws3 / name) &
          " push -q origin main")
        writeFile(ws3 / "repos" / (name & ".toml"),
          repoFragment(name, name & "-origin") &
          # ``lead`` develops against ``follower``, so the RA-21 pre-push
          # scope of a ``lead`` push is {lead, follower}. Without the edge the
          # sibling's move is out of scope, the gate calls the lock current,
          # and the refusal under test never fires — a fixture that would have
          # passed for the wrong reason.
          (if name == "lead": "depends = [\"follower\"]\n" else: ""))

      writeFile(ws3 / "projects" / "pair.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"pair\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lead-origin\"\nfetch = \"file://" &
          scratch / "c-origin-lead.git" & "\"\n\n" &
        "[[remote]]\nname = \"follower-origin\"\nfetch = \"file://" &
          scratch / "c-origin-follower.git" & "\"\n\n" &
        "includes = [\n  \"repos/lead.toml\",\n  \"repos/follower.toml\",\n]\n")
      # Different seeds ⇒ different SHAs, so "which repo is this record
      # anchored at" is observable at all.
      seedRepo3("lead", "lead seed\n")
      seedRepo3("follower", "follower seed\n")

      let store3 = ws3 / ".repro" / "manifests"
      createDir(parentDir(store3))
      let store3Origin = scratch / "c-origin-manifests.git"
      discard requireGit(q(gitBin) & " init -q --bare -b main " & q(store3Origin))
      discard requireGit(q(gitBin) & " clone -q " &
        q("file://" & store3Origin) & " " & q(store3))
      gitConfig(gitBin, store3)
      writeFile(store3 / "README.md", "lock store\n")
      discard requireGit(q(gitBin) & " -C " & q(store3) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(store3) & " commit -qm seed")
      discard requireGit(q(gitBin) & " -C " & q(store3) & " push -q origin main")

      writeWorkspaceBranch(ws3, project = "pair", branch = "main")

      proc head3(repo: string): string =
        requireGit(q(gitBin) & " -C " & q(ws3 / repo) &
          " rev-parse HEAD").strip()

      let leadSha = head3("lead")
      check leadSha != head3("follower")

      # Publish the immutable record at ``lead``'s commit.
      let seed3 = run(reproAbs & " workspace lock --workspace-root=" & q(ws3) &
        " --trigger-repo=lead")
      checkpoint("case C seed lock: exit " & $seed3.code & "\n" & seed3.output)
      check seed3.code == 0
      let burned = store3 / "locks" / "pair" / "lead" / (leadSha & ".toml")
      check fileExists(burned)
      let burnedBody = readFile(burned)

      # The sibling moves. ``lead`` does NOT, so its coordinate is unchanged
      # and already occupied by published history.
      writeFile(ws3 / "follower" / "work.txt", "follower work\n")
      discard requireGit(q(gitBin) & " -C " & q(ws3 / "follower") & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(ws3 / "follower") &
        " commit -qm \"follower work\"")
      discard requireGit(q(gitBin) & " -C " & q(ws3 / "follower") &
        " push -q origin main")
      check head3("lead") == leadSha

      let refs3 = scratch / "case-c-refs.txt"
      writeFile(refs3, "refs/heads/main " & leadSha &
        " refs/heads/main " & leadSha & "\n")

      proc gate3(): tuple[code: int; output: string] =
        run(reproAbs & " check --mode=pre-push --write-report" &
          " --workspace-root=" & q(ws3) &
          " --current-repo=" & q(ws3 / "lead") &
          " --pushed-refs=" & q(refs3) & " --json", cwd = ws3 / "lead")

      let refusal3 = gate3()
      checkpoint("case C gate: exit " & $refusal3.code & "\n" & refusal3.output)
      require refusal3.code == 2
      var lockFailure: JsonNode = nil
      for f in parseFile(ws3 / ".repro" / "build" / "reports" /
          "check-report.json")["failures"]:
        if f["property"].getStr() == "lock-failure":
          lockFailure = f
          break
      require lockFailure != nil
      let evidence3 = lockFailure["evidence"].getStr()
      let remediation3 = lockFailure["remediation"].getStr()
      checkpoint("case C evidence: " & evidence3)
      checkpoint("case C remediation: " & remediation3)
      # This is the failure we are talking about, not some other lock failure.
      check evidence3.contains("immutable lock record already exists")
      # The historical wrong answer, in its own words.
      check not remediation3.contains("re-run 'repro check'")

      # ---- the remedy is a command, and the command runs -----------------
      let commands3 = namedReproCommands(remediation3)
      checkpoint("case C commands named: " & commands3.join(" | "))
      check commands3.len >= 1
      for cmd in commands3:
        let res = run(reproAbs & cmd["repro".len .. ^1], cwd = ws3 / "lead")
        checkpoint("ran `" & cmd & "` -> exit " & $res.code & "\n" & res.output)
        check res.code == 0

      # ---- and running it CLEARS the refusal it was offered for ----------
      let after3 = gate3()
      checkpoint("case C gate after remedy: " & after3.output)
      check after3.code == 0
      # Published history was kept, exactly as the refusal promised.
      check readFile(burned) == burnedBody
