## The pre-push gate separates "does this push PUBLISH this HEAD" from
## "does this push ORPHAN something the workspace depends on".
##
## Before this suite existed, ``evaluateOutgoingCurrent`` fused the two: any
## non-fast-forward update was denied the provisional ``outgoing-current``
## classification, so rebasing a feature branch onto a moved mainline and
## force-pushing it — the ordinary way to keep a PR current — was reported as
##
##   reprobuild: unpublished — resolve 'outgoing update is not a fast-forward'
##   in <repo> — re-running 'git push' will not help, this refusal IS that push
##
## which says the repo is unpublished while refusing the push that publishes
## it. The only way through was ``--no-verify``, i.e. disabling the whole
## gate, so the rule taught its own bypass on a legitimate case.
##
## Every case below is a REFUSAL or the CONVERSE of one, which is precisely
## the shape a from-outside suite reaches by accident least often, so each
## refusal is paired with a near-identical acceptance that differs only in the
## fact the refusal claims to be about:
##
##   * a fast-forward (and a branch create) still passes — the case that works
##     today and that a careless fix breaks;
##   * a rebased FEATURE-branch force-push now passes, including when a lock
##     record keyed at the discarded commit exists (the state every previous
##     push leaves behind, and the reason a naive "is it pinned" test would
##     refuse every rebase);
##   * the same force-push is REFUSED (``orphans-locked-commit``) once a
##     SIBLING repo's lock — keyed at a commit this push does NOT discard —
##     pins the commit being discarded, and the refusal names that record;
##   * a force-push of the manifest-declared MAINLINE is refused
##     (``mainline-history-rewrite``) naming the branch, while the identical
##     rewrite on a feature branch passes;
##   * a non-fast-forward whose old tip is not a local commit is refused
##     (``history-rewrite-unverifiable``) telling the operator to fetch,
##     rather than telling them to run the push being refused.
##
## No mocks. Real ``git init``/``git init --bare`` repositories, the real
## ``repro hooks ensure`` hook installation, and real ``git push`` /
## ``repro hooks dispatch pre-push`` entry points. The lock records the
## orphan case reads are the ones the GATE ITSELF wrote during earlier
## pushes in the same fixture — no lock file is hand-authored, so the check
## cannot pass against a shape the product never produces. No network.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc sourceRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  let candidate =
    if configured.len > 0: configured
    else: sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
  requireBinary(candidate, "reprobuild.apps.repro")

type
  EnvSnapshot = object
    existed: bool
    value: string

  Fixture = object
    scratch: string
    workspace: string
    app: string
    lib: string
    appOrigin: string
    libOrigin: string
    gitBin: string
    reproBin: string

proc overrideEnv(name, value: string): EnvSnapshot =
  result = EnvSnapshot(existed: existsEnv(name), value: getEnv(name))
  putEnv(name, value)

proc restoreEnv(name: string; snapshot: EnvSnapshot) =
  if snapshot.existed: putEnv(name, snapshot.value)
  else: delEnv(name)

proc gitIn(fx: Fixture; repo: string; args: openArray[string];
    required = true): tuple[code: int; output: string] =
  var argv = @[fx.gitBin, "-C", repo]
  argv.add(args)
  let res = runShell(shellCommand(argv))
  result = (res.code, res.output)
  if required and result.code != 0:
    checkpoint("git failed: " & argv.join(" ") & "\n" & res.output)
    quit 1

proc headOf(fx: Fixture; repo: string): string =
  fx.gitIn(repo, ["rev-parse", "HEAD"]).output.strip()

proc commitIn(fx: Fixture; repo, label: string): string =
  writeFile(repo / "content.txt", label & "\n")
  discard fx.gitIn(repo, ["add", "content.txt"])
  discard fx.gitIn(repo, ["commit", "-m", label])
  fx.headOf(repo)

proc writeManifest(fx: Fixture) =
  # Native flat layout: membership (``projects/`` + ``repos/``) at the
  # workspace root, and the LOCK STORE as its own ``.repro/manifests`` git
  # checkout with an upstream. ``pickManifestLayerRoot`` only routes locks to
  # that store when it really is a git checkout, so a fixture without one
  # produces no lock records at all — and an orphan-detection assertion over a
  # workspace with no locks would pass against any implementation.
  let manifests = fx.workspace
  createDir(manifests / "projects")
  createDir(manifests / "repos")
  createDir(fx.workspace / ".repro")
  writeFile(fx.workspace / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\nbranch = \"main\"\n")
  writeFile(manifests / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" &
      fx.appOrigin.replace('\\', '/') & "\"\n\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" &
      fx.libOrigin.replace('\\', '/') & "\"\n\n" &
    "includes = [\"repos/app.toml\", \"repos/lib.toml\"]\n")
  # ``revision = "main"`` is the manifest's declaration of this repo's
  # mainline; the mainline clause below refuses a rewrite of exactly that
  # branch name and of no other.
  writeFile(manifests / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"app-origin\"\nrevision = \"main\"\n")
  writeFile(manifests / "repos" / "lib.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"lib\"\npath = \"lib\"\n" &
    "remote = \"lib-origin\"\nrevision = \"main\"\n")

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-rewrite-orphan-" & slug & "-", "")
  result.workspace = result.scratch / "workspace"
  result.app = result.workspace / "app"
  result.lib = result.workspace / "lib"
  result.appOrigin = result.scratch / "origin-app.git"
  result.libOrigin = result.scratch / "origin-lib.git"
  result.gitBin = gitBin
  result.reproBin = reproBinary()
  createDir(result.workspace)
  for origin in [result.appOrigin, result.libOrigin]:
    discard require(q(gitBin) & " init --bare -b main " & q(origin))
  for (path, remoteName, origin) in [
      (result.app, "app-origin", result.appOrigin),
      (result.lib, "lib-origin", result.libOrigin)]:
    discard require(q(gitBin) & " init -b main " & q(path))
    discard result.gitIn(path, ["config", "user.email",
      "tester@example.invalid"])
    discard result.gitIn(path, ["config", "user.name", "Rewrite Tester"])
    discard result.gitIn(path, ["remote", "add", remoteName, origin])
    writeFile(path / "content.txt", "seed\n")
    discard result.gitIn(path, ["add", "content.txt"])
    discard result.gitIn(path, ["commit", "-m", "seed"])
    discard result.gitIn(path, ["push", "--no-verify", "-u", remoteName,
      "main"])
  result.writeManifest()
  # The lock store: a real git checkout with a real upstream, so the gate's
  # write AND its publish both run the production path.
  let storeOrigin = result.scratch / "origin-manifests.git"
  let store = result.workspace / ".repro" / "manifests"
  discard require(q(gitBin) & " init --bare -b main " & q(storeOrigin))
  discard require(q(gitBin) & " clone " & q("file://" & storeOrigin) & " " &
    q(store))
  discard result.gitIn(store, ["config", "user.email",
    "tester@example.invalid"])
  discard result.gitIn(store, ["config", "user.name", "Rewrite Tester"])
  writeFile(store / "README.md", "lock store\n")
  discard result.gitIn(store, ["add", "-A"])
  discard result.gitIn(store, ["commit", "-m", "seed"])
  discard result.gitIn(store, ["push", "--no-verify", "origin", "main"])
  # The membership root is itself a repo in the native layout.
  discard require(q(gitBin) & " init -b main " & q(result.workspace))
  discard result.gitIn(result.workspace, ["config", "user.email",
    "tester@example.invalid"])
  discard result.gitIn(result.workspace, ["config", "user.name",
    "Rewrite Tester"])
  writeFile(result.workspace / ".gitignore", "/.repro/\n/app/\n/lib/\n")
  discard result.gitIn(result.workspace, ["add", "-A"])
  discard result.gitIn(result.workspace, ["commit", "-m", "seed manifests"])
  let ensured = runShell(shellCommand(@[result.reproBin, "hooks", "ensure",
    "--vcs", "--workspace-root=" & result.workspace, result.workspace]))
  if ensured.code != 0:
    checkpoint("hook ensure failed:\n" & ensured.output)
    quit 1
  # Post-commit / post-merge / post-checkout refreshes are orthogonal here and
  # would rewrite locks between the steps this suite is measuring.
  for repo in [result.app, result.lib]:
    for name in ["post-commit", "post-merge", "post-checkout"]:
      for suffix in ["", ".repro-managed", ".repro-local"]:
        let path = repo / ".git" / "hooks" / (name & suffix)
        if fileExists(path): removeFile(path)

proc lockFilesUnder(fx: Fixture): seq[string] =
  ## Every lock record the gate has written in this workspace, whichever root
  ## it picked. Used only to prove the fixture reached the state the assertion
  ## claims — a suite that asserts "the force-push was refused" against a
  ## workspace with no locks at all would pass trivially.
  for root in [fx.workspace / ".repro" / "manifests", fx.workspace]:
    let locks = root / "locks"
    if not dirExists(locks): continue
    for path in walkDirRec(locks):
      if path.endsWith(".toml"):
        result.add(path)

proc lockNaming(fx: Fixture; sha: string): seq[string] =
  ## Lock records that PIN ``sha`` (anywhere in their body).
  for path in fx.lockFilesUnder():
    let body =
      try: readFile(path)
      except CatchableError: ""
    if sha in body:
      result.add(path)

template refuses(res: tuple[code: int; output: string]; needles: openArray[string];
    forbidden: openArray[string]) =
  ## A refusal must be refused FOR THE STATED REASON, and must not carry the
  ## self-refuting text the old gate emitted. Asserting only ``code != 0``
  ## would pass against an implementation that refuses everything.
  if res.code == 0:
    checkpoint("push unexpectedly passed:\n" & res.output)
  check res.code != 0
  for needle in needles:
    if needle notin res.output:
      checkpoint("missing '" & needle & "' in:\n" & res.output)
    check needle in res.output
  for bad in forbidden:
    if bad in res.output:
      checkpoint("forbidden '" & bad & "' in:\n" & res.output)
    check bad notin res.output

template passes(res: tuple[code: int; output: string]) =
  if res.code != 0:
    checkpoint("push unexpectedly refused:\n" & res.output)
  check res.code == 0

template withFixture(gitBin, slug: string; body: untyped) =
  var fx {.inject.} = setupFixture(gitBin, slug)
  defer: removeDir(fx.scratch)
  let priorRepro = overrideEnv("REPROBUILD_REPRO", fx.reproBin)
  let priorSystem = overrideEnv("REPROBUILD_SYSTEM_CONFIG",
    fx.scratch / "no-system.toml")
  let priorUser = overrideEnv("REPROBUILD_USER_CONFIG",
    fx.scratch / "no-user.toml")
  let priorVcsPrivate = overrideEnv("REPROBUILD_VCS_PRIVATE_CONFIG",
    fx.scratch / "no-vcs-private.toml")
  defer:
    restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", priorVcsPrivate)
    restoreEnv("REPROBUILD_USER_CONFIG", priorUser)
    restoreEnv("REPROBUILD_SYSTEM_CONFIG", priorSystem)
    restoreEnv("REPROBUILD_REPRO", priorRepro)
  body

# ---------------------------------------------------------------------------

suite "pre-push gate — publication versus history rewrite":

  test "create and fast-forward branch updates still pass":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      withFixture(gitBin, "forward"):
        discard fx.gitIn(fx.app, ["checkout", "-b", "feature"])
        discard fx.commitIn(fx.app, "feature one")
        # Branch CREATE (remote-old is the zero OID).
        passes(fx.gitIn(fx.app, ["push", "app-origin", "feature"],
          required = false))
        discard fx.commitIn(fx.app, "feature two")
        # Genuine FAST-FORWARD. This is the case that already worked; a fix
        # that granted publication unconditionally would still pass it, but a
        # fix that mis-shaped the classifier would break it here.
        passes(fx.gitIn(fx.app, ["push", "app-origin", "feature"],
          required = false))

  test "a rebased feature branch force-push publishes instead of refusing":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      withFixture(gitBin, "rebase"):
        discard fx.gitIn(fx.app, ["checkout", "-b", "feature"])
        let discarded = fx.commitIn(fx.app, "feature work")
        passes(fx.gitIn(fx.app, ["push", "app-origin", "feature"],
          required = false))
        # The gate wrote a lock keyed at, and pinning, the commit that is
        # about to be discarded. That is the state EVERY successful push
        # leaves behind, so a check that merely asked "is the orphaned commit
        # pinned anywhere" would refuse every rebase in a locked workspace
        # while protecting nothing: the snapshot it guards is anchored at a
        # commit that will no longer exist.
        check fx.lockNaming(discarded).len > 0

        # Rewrite: drop the pushed commit and put different work in its place.
        discard fx.gitIn(fx.app, ["reset", "--hard", "main"])
        let rebased = fx.commitIn(fx.app, "feature work, rebased")
        check rebased != discarded
        passes(fx.gitIn(fx.app, ["push", "--force", "app-origin", "feature"],
          required = false))
        check fx.gitIn(fx.app,
          ["ls-remote", "app-origin", "refs/heads/feature"])
          .output.strip().startsWith(rebased)

  test "a force-push orphaning a sibling's locked commit is refused by name":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      withFixture(gitBin, "orphan"):
        discard fx.gitIn(fx.app, ["checkout", "-b", "feature"])
        let depended = fx.commitIn(fx.app, "app work others will pin")
        passes(fx.gitIn(fx.app, ["push", "app-origin", "feature"],
          required = false))
        # A SIBLING repo now publishes while app sits at ``depended``. The
        # lock the gate writes for lib is keyed at lib's own commit — which
        # this app push does not discard — and pins app at ``depended``.
        discard fx.commitIn(fx.lib, "lib work")
        passes(fx.gitIn(fx.lib, ["push", "lib-origin", "main"],
          required = false))
        let libSha = fx.headOf(fx.lib)
        var siblingRecords: seq[string]
        for path in fx.lockNaming(depended):
          if libSha in extractFilename(path):
            siblingRecords.add(path)
        # One more app commit on top, so the pinned commit is an ANCESTOR of
        # the branch tip being replaced rather than the tip itself. Without
        # this the orphan set could be built from ``remote-old`` alone and the
        # reachability walk would never be exercised.
        let tip = fx.commitIn(fx.app, "app work on top")
        passes(fx.gitIn(fx.app, ["push", "app-origin", "feature"],
          required = false))
        check tip != depended
        if siblingRecords.len == 0:
          checkpoint("fixture did not produce a sibling-keyed lock pinning " &
            depended & "; records: " & fx.lockFilesUnder().join(", "))
        check siblingRecords.len > 0

        discard fx.gitIn(fx.app, ["reset", "--hard", "main"])
        let rebased = fx.commitIn(fx.app, "app work, rebased")
        let refused = fx.gitIn(fx.app,
          ["push", "--force", "app-origin", "feature"], required = false)
        refuses(refused,
          needles = ["orphans-locked-commit", depended, libSha,
                     "is publishable"],
          # The push publishes HEAD; saying otherwise, or telling the
          # operator to run the push being refused, is the defect. Naming
          # non-fast-forwardness as a FACT is fine; treating it as the
          # verdict was the bug.
          forbidden = ["unpublished", "will not help"])
        # The commit the refusal names is the PINNED ANCESTOR, not the branch
        # tip being replaced: ``tip`` is what the remote holds, ``depended``
        # is one commit behind it, and only a reachability walk over the
        # discarded range can produce the latter.
        check ("pins app at " & depended) in refused.output
        # The refusal must not have been carried out: the remote branch still
        # holds the history the lock depends on.
        check fx.gitIn(fx.app,
          ["ls-remote", "app-origin", "refs/heads/feature"])
          .output.strip().startsWith(tip)
        check rebased != depended

        # CONVERSE, differing only in whether anything still depends on the
        # discarded commit: push the rewrite to a branch nothing pins, and
        # the identical rewrite is published.
        passes(fx.gitIn(fx.app,
          ["push", "app-origin", "HEAD:refs/heads/feature-v2"],
          required = false))

  test "a force-push of the declared mainline is refused naming the branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      withFixture(gitBin, "mainline"):
        let published = fx.commitIn(fx.app, "mainline work")
        passes(fx.gitIn(fx.app, ["push", "app-origin", "main"],
          required = false))
        discard fx.gitIn(fx.app, ["reset", "--hard", "HEAD~1"])
        let rewritten = fx.commitIn(fx.app, "mainline rewritten")
        let refused = fx.gitIn(fx.app,
          ["push", "--force", "app-origin", "main"], required = false)
        refuses(refused,
          needles = ["mainline-history-rewrite", "'main'", "is publishable"],
          forbidden = ["unpublished", "will not help"])
        check fx.gitIn(fx.app, ["ls-remote", "app-origin", "refs/heads/main"])
          .output.strip().startsWith(published)

        # CONVERSE: the SAME rewritten history, differing only in the branch
        # it is pushed to, is published. Without this the mainline clause
        # would be indistinguishable from a blanket force-push refusal.
        passes(fx.gitIn(fx.app,
          ["push", "app-origin", "HEAD:refs/heads/side"], required = false))
        check fx.gitIn(fx.app, ["ls-remote", "app-origin", "refs/heads/side"])
          .output.strip().startsWith(rewritten)

  test "a rewrite whose old tip is not local is refused with a fetch remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      withFixture(gitBin, "opaque"):
        # receive-pack cannot advertise a branch tip that is absent from the
        # sender, so the only falsifiable boundary for this shape is the
        # installed dispatcher fed real framing with a real-width OID that
        # names no local object. The destination is a FEATURE branch, so the
        # mainline clause cannot be what fires.
        discard fx.gitIn(fx.app, ["checkout", "-b", "feature"])
        let head = fx.commitIn(fx.app, "feature work")
        let absent = repeat('a', head.len)
        let refs = fx.scratch / "opaque-refs"
        writeFile(refs, "refs/heads/feature " & head &
          " refs/heads/feature " & absent & "\n")
        let dispatched = runShell(shellCommand(@[fx.reproBin, "hooks",
          "dispatch", "pre-push", "--protocol=2",
          "--repo-root=" & fx.app, "--refs-file=" & refs,
          "--", "app-origin", fx.appOrigin]))
        let observed: tuple[code: int; output: string] =
          (code: dispatched.code, output: dispatched.output)
        refuses(observed,
          needles = ["history-rewrite-unverifiable", absent, "fetch",
                     "is publishable"],
          forbidden = ["unpublished", "will not help"])
