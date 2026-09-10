## NF-2 shared fixture — a REAL multi-repo workspace on a real filesystem.
##
## Deliberately not a `t_*.nim` file: `scripts/generate_test_edges.nim` only
## discovers `t_*` / `test_*` stems, so this helper is never compiled as a test
## in its own right (the same convention `tc5_cert_signing_helpers.nim` follows).
##
## ## Test-double policy for every NF-2 case: NO mocks, doubles or fakes
##
## The repository's policy is that "every use of mock objects in tests must be
## explicitly justified in the header comment". Nothing here is mocked, so the
## justification is the absence:
##
##   * real bare git origins and real `git clone`d checkouts;
##   * a real committed `repro.lock` in the shipped
##     `reprobuild.solved-graph-lock.v2` shape;
##   * a real `flake.lock` in nix's own on-disk format (its shape was taken
##     from a lock `nix flake lock` actually generated against this fixture);
##   * the real `./build/bin/repro` binary;
##   * a REAL `.git/hooks/pre-commit`, fired by git itself during a real
##     `git commit` / `git commit --amend` / `git rebase`. The refresh is never
##     "simulated"; every case below observes what an actual commit produced.
##
## ### The one component that is written here rather than installed
##
## `installPreCommitDispatch` writes the hook FILE instead of obtaining it from
## `repro hooks ensure --vcs`. That is not a double of the thing under test —
## the hook body it writes issues the byte-identical dispatch the managed body
## issues (`cd $(git rev-parse --show-toplevel)` then
## `repro hooks dispatch pre-commit --repo-root "$REPO_ROOT" --`, see
## `vcsManagedHookBody`) and runs the same real binary. What it omits is the
## managed body's interpreter resolution and contract handshake, which are
## about INSTALLATION rather than about the refresh, and which a stale `repro`
## on `PATH` can silently turn into a no-op — producing a vacuous green here.
##
## The installer is therefore covered by its own case rather than assumed:
## `t_hooks_ensure_installs_a_managed_pre_commit_hook` runs the real
## `repro hooks ensure --vcs`, asserts the managed `pre-commit` dispatcher and
## its `.repro-managed` body are on disk, that a preserved user hook still runs
## first, and that a real `git commit` through THAT hook refreshes and stages
## the lock.
##
## The one thing that is NOT exercised end-to-end by default is `nix` itself:
## the cases assert on `flake.lock`'s CONTENT, which is what CI, a colleague
## and a fresh checkout consume. Where a nix-level check adds something the
## content check cannot give (§5's "looked like it was working while doing
## nothing"), the case runs it and announces LOUDLY when nix is unavailable.
##
## ## Topology
##
##   <scratch>/
##     origin-<repo>.git         real bare origins for six repos
##     ws/                       the workspace root
##       .repro/workspace.toml   the workspace shell marker
##       repro.lock              the committed lock (MO-2 workspace marker)
##       alpha/ beta/ gamma/     siblings named by flake inputs, each a flake
##       delta/ epsilon/         siblings NOT named by any flake input
##       app/                    the repo whose commit fires the hook;
##                               carries flake.nix + flake.lock
##
## `app`'s lock entry declares `depends = "alpha,beta,epsilon"`, so its
## develop-set closure is {app, alpha, beta, epsilon} and `delta` is outside it.

import std/[os, osproc, strutils, tempfiles, unittest]

const
  Nf2Repos* = ["alpha", "beta", "gamma", "delta", "epsilon", "app"]
  Nf2FlakeInputRepos* = ["alpha", "beta", "gamma"]
    ## The repos the fixture's `flake.nix` names (as `<repo>-src`).

type
  Nf2Fixture* = object
    scratch*: string
    ws*: string
    app*: string
    gitBin*: string
    repro*: string
    seedSha*: array[6, string]

proc q*(value: string): string = quoteShell(value)

proc run*(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireCmd*(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    # BOTH channels. `checkpoint` only surfaces attached to a failing `check`,
    # and this path ends the process instead — so a setup command that failed
    # used to take the binary down having printed nothing at all, leaving an
    # exit status and no reason. Whatever else a test harness may swallow, the
    # reason a run stopped has to reach somebody.
    stderr.writeLine("FIXTURE ABORT: command failed: " & command &
      "\n  exit=" & $res.code & "\n  output:\n" & res.output)
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc reproBinaryPath*(): string =
  ## `repro` is a build-graph artifact (`reprobuild.apps.repro` ->
  ## `build/bin/repro`), built by `just bootstrap` before the suite runs.
  "." / "build" / "bin" / addFileExt("repro", ExeExt)

proc nf2Prerequisites*(caseName: string): bool =
  ## True when the case can run. A missing prerequisite is announced LOUDLY
  ## with the reason and the remedy — never a silent pass.
  let gitBin = findExe("git")
  let repro = reproBinaryPath()
  if gitBin.len > 0 and fileExists(repro):
    return true
  echo "SKIPPED (loudly): " & caseName & " needs `git` on PATH and a built " &
    reproBinaryPath() & "; git=" &
    (if gitBin.len == 0: "MISSING" else: gitBin) & " repro=" &
    (if fileExists(repro): "present" else: "UNBUILT — run `just bootstrap`")
  false

proc gitIn*(fx: Nf2Fixture; repo: string; args: string): string =
  requireCmd(q(fx.gitBin) & " -C " & q(repo) & " " & args)

proc headOf*(fx: Nf2Fixture; repoDir: string): string =
  gitIn(fx, repoDir, "rev-parse HEAD").strip()

proc siblingDir*(fx: Nf2Fixture; name: string): string = fx.ws / name

proc lockPath*(fx: Nf2Fixture): string = fx.app / "flake.lock"

proc lockDep(scratch, name, path, sha, depends, origin: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
  "\", coord_kind = \"vcs\", url = \"file://" & scratch / ("origin-" & origin & ".git") &
  "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"" & depends & "\", groups = \"\" }"

proc seedOrigin(fx: Nf2Fixture; name: string): string =
  ## One real bare origin plus one real seeded working tree, pushed to it.
  ##
  ## The seed content is keyed on the repo NAME, and that is load-bearing: a
  ## commit SHA hashes (tree, message, author, committer, timestamps), so six
  ## repos seeded back to back with identical content in the same clock second
  ## would collide on one SHA and make every "which repo does this pin name"
  ## assertion below meaningless.
  let origin = fx.scratch / ("origin-" & name & ".git")
  let work = fx.scratch / ("seed-" & name)
  discard requireCmd(q(fx.gitBin) & " init --bare -q -b main " & q(origin))
  discard requireCmd(q(fx.gitBin) & " init -q -b main " & q(work))
  discard requireCmd(q(fx.gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireCmd(q(fx.gitBin) & " -C " & q(work) &
    " config user.name \"NF2 Tester\"")
  # Every sibling is a FLAKE: `--override-input <n> path:<dir>` requires the
  # directory to be one, and NF-1 refuses to substitute a sibling without a
  # `flake.nix`.
  writeFile(work / "flake.nix", "{ outputs = _: { }; }\n")
  writeFile(work / "marker.txt", name & " revision 1\n")
  discard requireCmd(q(fx.gitBin) & " -C " & q(work) & " add -A")
  discard requireCmd(q(fx.gitBin) & " -C " & q(work) & " commit -q -m " &
    q("seed " & name))
  discard requireCmd(q(fx.gitBin) & " -C " & q(work) & " remote add origin " &
    q(origin))
  discard requireCmd(q(fx.gitBin) & " -C " & q(work) & " push -q origin main")
  requireCmd(q(fx.gitBin) & " -C " & q(work) & " rev-parse HEAD").strip()

proc originUrl*(fx: Nf2Fixture; name: string): string =
  "file://" & (fx.scratch / ("origin-" & name & ".git"))

proc lockedNode*(name, url, rev, narHash: string; indent: string): string =
  ## One `flake.lock` node in nix's own on-disk shape. `lastModified`,
  ## `narHash` and `revCount` are present because a real lock carries them —
  ## they are exactly the fields a revision move has to DROP, so a fixture
  ## without them could not witness that.
  indent & "\"" & name & "\": {\n" &
  indent & "  \"locked\": {\n" &
  indent & "    \"lastModified\": 1787946353,\n" &
  indent & "    \"narHash\": \"" & narHash & "\",\n" &
  indent & "    \"ref\": \"main\",\n" &
  indent & "    \"rev\": \"" & rev & "\",\n" &
  indent & "    \"revCount\": 1,\n" &
  indent & "    \"type\": \"git\",\n" &
  indent & "    \"url\": \"" & url & "\"\n" &
  indent & "  },\n" &
  indent & "  \"original\": {\n" &
  indent & "    \"ref\": \"main\",\n" &
  indent & "    \"type\": \"git\",\n" &
  indent & "    \"url\": \"" & url & "\"\n" &
  indent & "  }\n" &
  indent & "}"

proc nf2FlakeLockText*(fx: Nf2Fixture; alphaRev, betaRev, gammaRev: string):
    string =
  ## The fixture's `flake.lock`.
  ##
  ## `nixpkgs` is written with its members in a DELIBERATELY unusual order and
  ## at a different indent from every other node. That is the witness for
  ## "only overridden nodes are rewritten": a refresh that parses the document
  ## and serialises it back would normalise this node's shape even though
  ## nothing about it changed, and the byte comparison would catch it.
  "{\n" &
  "  \"nodes\": {\n" &
  lockedNode("alpha-src", originUrl(fx, "alpha"), alphaRev,
    "sha256-fv2PzTwKsfeBptF8u/G0w9eh6GDsib/62l5cyuKNGYM=", "    ") & ",\n" &
  lockedNode("beta-src", originUrl(fx, "beta"), betaRev,
    "sha256-EZvvEKnc/QXEXlosW7OiNDncXiBneXs4liR/64D3A90=", "    ") & ",\n" &
  lockedNode("gamma-src", originUrl(fx, "gamma"), gammaRev,
    "sha256-8CsSWf5teLoXzC7ay1QzNPN9tP204vk496y/wq+S/Lc=", "    ") & ",\n" &
  "    \"flake-utils\": {\n" &
  "      \"locked\": {\n" &
  "        \"lastModified\": 1731533236,\n" &
  "        \"narHash\": \"sha256-l0KFg5HjrsfsO/JpG+r7fRrqm12kzFHyUHqHCVpMMbI=\",\n" &
  "        \"owner\": \"numtide\",\n" &
  "        \"repo\": \"flake-utils\",\n" &
  "        \"rev\": \"11707dc2f618dd54ca8739b309ec4fc024de578b\",\n" &
  "        \"type\": \"github\"\n" &
  "      },\n" &
  "      \"original\": { \"owner\": \"numtide\", \"repo\": \"flake-utils\", \"type\": \"github\" }\n" &
  "    },\n" &
  "        \"nixpkgs\": {\n" &
  "            \"locked\": {\n" &
  "                \"type\": \"github\",\n" &
  "                \"rev\": \"5e4fbfb6b3de1aa2872b76d49fafc942626e2add\",\n" &
  "                \"owner\": \"NixOS\",\n" &
  "                \"narHash\": \"sha256-OZiZ3m8SCMfh3B6bfGC/Bm4x3qc1m2SVEAlkV6iY7Yg=\",\n" &
  "                \"repo\": \"nixpkgs\",\n" &
  "                \"lastModified\": 1735563628\n" &
  "            },\n" &
  "            \"original\": {\n" &
  "                \"id\": \"nixpkgs\",\n" &
  "                \"type\": \"indirect\"\n" &
  "            }\n" &
  "        },\n" &
  "    \"root\": {\n" &
  "      \"inputs\": {\n" &
  "        \"alpha-src\": \"alpha-src\",\n" &
  "        \"beta-src\": \"beta-src\",\n" &
  "        \"flake-utils\": \"flake-utils\",\n" &
  "        \"gamma-src\": \"gamma-src\",\n" &
  "        \"nixpkgs\": \"nixpkgs\"\n" &
  "      }\n" &
  "    }\n" &
  "  },\n" &
  "  \"root\": \"root\",\n" &
  "  \"version\": 7\n" &
  "}\n"

proc preCommitHookPath*(fx: Nf2Fixture): string =
  fx.app / ".git" / "hooks" / "pre-commit"

proc installPreCommitDispatch*(fx: Nf2Fixture) =
  ## A real `.git/hooks/pre-commit`, issuing the byte-identical dispatch the
  ## managed hook body issues (`vcsManagedHookBody`, the non-`pre-push` arm):
  ##
  ##     REPO_ROOT=$(git rev-parse --show-toplevel …); cd "$REPO_ROOT"
  ##     "$REPRO_CMD" hooks dispatch <name> --repo-root "$REPO_ROOT" -- "$@"
  ##
  ## The binary is named by ABSOLUTE PATH rather than resolved from `PATH`,
  ## which is the whole reason this file is written rather than installed: a
  ## developer machine's `PATH` carries whatever `repro` the dev shell pins,
  ## the managed body's contract handshake would then refuse and fire nothing,
  ## and every assertion below would pass over a hook that never ran.
  ##
  ## `set -e` and the propagated exit status are kept, because "this hook can
  ## abort the commit" is a property under test: a pre-commit hook that cannot
  ## fail the commit would make the "a dirty sibling does not refuse the
  ## commit" case vacuous.
  createDir(fx.app / ".git" / "hooks")
  writeFile(preCommitHookPath(fx),
    "#!/usr/bin/env sh\n" &
    "set -eu\n" &
    "REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n" &
    "cd \"$REPO_ROOT\"\n" &
    "REPRO_STATUS=0\n" &
    q(fx.repro) & " hooks dispatch pre-commit --repo-root \"$REPO_ROOT\" " &
      "-- \"$@\" || REPRO_STATUS=$?\n" &
    "exit $REPRO_STATUS\n")
  var perms = getFilePermissions(preCommitHookPath(fx))
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(preCommitHookPath(fx), perms)

proc removePreCommitDispatch*(fx: Nf2Fixture) =
  ## Take the hook back out, for the arms that need a commit git does NOT
  ## refresh (setting up a "the lock is stale" starting state).
  if fileExists(preCommitHookPath(fx)): removeFile(preCommitHookPath(fx))

proc setupNf2Fixture*(label: string): Nf2Fixture =
  ## Build the whole workspace. Returns a fixture whose `flake.lock` names
  ## exactly the revision every sibling checkout is sitting at — the
  ## "nothing has drifted" starting state.
  result.gitBin = findExe("git")
  result.repro = absolutePath(reproBinaryPath())
  result.scratch = createTempDir("nf2-" & label & "-", "")
  result.ws = result.scratch / "ws"
  result.app = result.ws / "app"
  createDir(result.ws)

  var shas: seq[string]
  for name in Nf2Repos:
    let sha = seedOrigin(result, name)
    shas.add(sha)
    discard requireCmd(q(result.gitBin) & " clone -q " &
      q(originUrl(result, name)) & " " & q(result.ws / name))
    discard requireCmd(q(result.gitBin) & " -C " & q(result.ws / name) &
      " config user.email tester@example.invalid")
    discard requireCmd(q(result.gitBin) & " -C " & q(result.ws / name) &
      " config user.name \"NF2 Tester\"")
  for i in 0 ..< Nf2Repos.len:
    result.seedSha[i] = shas[i]

  var deps: seq[string]
  # The workspace root itself, so the committed lock resolves to a project
  # whose repo set carries the `depends` edges `developSetClosure` walks.
  deps.add(lockDep(result.scratch, "nf2-root", ".", shas[5], "app", "app"))
  deps.add(lockDep(result.scratch, "app", "app", shas[5],
    "alpha,beta,epsilon", "app"))
  for i, name in Nf2Repos:
    if name == "app": continue
    deps.add(lockDep(result.scratch, name, name, shas[i], "", name))
  writeFile(result.ws / "repro.lock",
    "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
    "[lock]\n" &
    "platform = \"x86_64-linux\"\n" &
    "optimal = true\n" &
    "inputs_digest = \"nf2-fixture\"\n" &
    "variants = []\n" &
    "packages = []\n" &
    "deps = [" & deps.join(", ") & "]\n")

  createDir(result.ws / ".repro")
  writeFile(result.ws / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\n" &
    "project = \"nf2\"\n" &
    "branch = \"main\"\n")

  writeFile(result.app / "flake.nix",
    "{\n" &
    "  description = \"NF-2 fixture consumer\";\n" &
    "\n" &
    "  inputs = {\n" &
    "    alpha-src.url = \"git+" & originUrl(result, "alpha") & "?ref=main\";\n" &
    "    beta-src.url = \"git+" & originUrl(result, "beta") & "?ref=main\";\n" &
    "    gamma-src.url = \"git+" & originUrl(result, "gamma") & "?ref=main\";\n" &
    "    nixpkgs.url = \"github:NixOS/nixpkgs\";\n" &
    "    flake-utils.url = \"github:numtide/flake-utils\";\n" &
    "  };\n" &
    "\n" &
    "  outputs = _: { };\n" &
    "}\n")
  writeFile(lockPath(result),
    nf2FlakeLockText(result, shas[0], shas[1], shas[2]))
  discard requireCmd(q(result.gitBin) & " -C " & q(result.app) & " add -A")
  discard requireCmd(q(result.gitBin) & " -C " & q(result.app) &
    " commit -q -m " & q("add flake"))
  # Installed AFTER the seeding commit above, so the starting state is the one
  # the header describes — a lock that names exactly what every sibling is at —
  # rather than one an unobserved hook firing may already have moved.
  installPreCommitDispatch(result)

proc isolateNf2Config*(fx: Nf2Fixture) =
  ## Silence the host's own configuration layers so nothing outside the
  ## fixture can route this workspace's locks.
  putEnv("REPROBUILD_SYSTEM_CONFIG", fx.scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", fx.scratch / "no-user.toml")
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", fx.scratch / "no-vcs.toml")

proc releaseNf2Config*() =
  delEnv("REPROBUILD_SYSTEM_CONFIG")
  delEnv("REPROBUILD_USER_CONFIG")
  delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc moveSibling*(fx: Nf2Fixture; name, marker: string): string =
  ## Commit a new revision in a sibling checkout and return its SHA. This is
  ## the situation §3.1 describes: the shell builds THIS, the lock still names
  ## the previous one.
  let dir = siblingDir(fx, name)
  writeFile(dir / "marker.txt", name & " " & marker & "\n")
  discard requireCmd(q(fx.gitBin) & " -C " & q(dir) & " commit -q -a -m " &
    q(marker))
  headOf(fx, dir)

proc dirtySibling*(fx: Nf2Fixture; name: string) =
  ## Leave UNCOMMITTED modifications in a sibling's working tree.
  writeFile(siblingDir(fx, name) / "marker.txt",
    name & " uncommitted work nobody else can obtain\n")

proc tryCommitInApp*(fx: Nf2Fixture; message: string):
    tuple[code: int; output: string; head: string] =
  ## A real `git commit` in the repo that carries the flake — WHICH FIRES THE
  ## INSTALLED `pre-commit` HOOK. That is the whole point of the pre-commit
  ## placement: the refresh happens inside this call, before the tree object
  ## is written, so the commit it produces carries the refreshed lock.
  ##
  ## Returns the exit status rather than aborting on it, because "the commit
  ## SUCCEEDED" is an assertion several cases have to make: a hook that
  ## refuses a commit over a dirty sibling would be new behaviour the
  ## inherited policy does not ask for, and it would be invisible to a helper
  ## that simply quit.
  let stamp = message.replace(" ", "-")
  writeFile(fx.app / (stamp & ".txt"), message & "\n")
  discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
  let res = run(q(fx.gitBin) & " -C " & q(fx.app) & " commit -q -m " &
    q(message))
  (code: res.code, output: res.output, head: headOf(fx, fx.app))

proc commitInApp*(fx: Nf2Fixture; message: string): string =
  let res = tryCommitInApp(fx, message)
  if res.code != 0:
    checkpoint("git commit failed: " & $res.code & "\n" & res.output)
    quit 1
  res.head

proc firePreCommitHook*(fx: Nf2Fixture): tuple[code: int; output: string] =
  ## The EXACT argv the managed `pre-commit` hook dispatches, driven directly.
  ##
  ## Used only where a case needs the refresh WITHOUT a commit around it (the
  ## operator-verb arms, and the re-fire checks). The behavioural cases go
  ## through a real `git commit`, which fires the installed hook itself.
  run(q(fx.repro) & " hooks dispatch pre-commit --repo-root " & q(fx.app) &
    " --", cwd = fx.app)

proc nodeText*(lockText, node: string): string =
  ## The RAW text of one `flake.lock` node, from its key to its closing brace.
  ## Raw rather than parsed, because every "unchanged" assertion below is about
  ## BYTES: key order, indentation and spacing all have to survive, and a
  ## parsed comparison would call a reserialized node equal to the original.
  let key = "\"" & node & "\": {"
  let at = lockText.find(key)
  if at < 0: return ""
  var i = at + key.len - 1
  var depth = 0
  var inString = false
  while i < lockText.len:
    let c = lockText[i]
    if inString:
      if c == '\\': inc i
      elif c == '"': inString = false
    elif c == '"': inString = true
    elif c == '{': inc depth
    elif c == '}':
      dec depth
      if depth == 0: return lockText[at .. i]
    inc i
  ""

proc preCommitLog*(fx: Nf2Fixture): string =
  let path = fx.ws / ".repro" / "workspace" / "pre-commit-lock.log"
  if fileExists(path): readFile(path) else: ""

proc postCommitLog*(fx: Nf2Fixture): string =
  let path = fx.ws / ".repro" / "workspace" / "post-commit-lock.log"
  if fileExists(path): readFile(path) else: ""

proc lastFlakeLogLine*(fx: Nf2Fixture): string =
  ## The most recent `flake-lock …` line of the pre-commit log.
  ##
  ## Scoped deliberately: the log is append-only, so a bare `contains` over the
  ## whole file would match an outcome from an earlier firing in the same case.
  for line in preCommitLog(fx).splitLines():
    if line.contains(" flake-lock "): result = line

proc lockInCommit*(fx: Nf2Fixture; rev = "HEAD"): string =
  ## `flake.lock` AS THE COMMIT CARRIES IT, read out of git's object store.
  ##
  ## This is the assertion the whole pre-commit placement exists to make
  ## available. The working-tree file answers "was the refresh performed"; only
  ## this answers §13.1's question — is the lock part of the revision being
  ## formed, or a modification left behind for somebody to commit later?
  let res = run(q(fx.gitBin) & " -C " & q(fx.app) & " show " & q(rev & ":flake.lock"))
  if res.code != 0: "" else: res.output
