## RA-30 — ``repro health`` (the environment doctor).
##
## Integration test for the layer-by-layer diagnosis. The CLI dispatcher
## in ``libs/repro_cli_support/src/repro_cli_support.nim`` routes
## ``repro health`` to ``runHealthCommand``, which gathers a list of
## ``(name, status, detail, remedy)`` checks — the single source of truth
## shared by the human table, the ``--json`` view, and the ``--fix``
## remediation path.
##
## This test drives the hermetically controllable layers (workspace
## marker present/absent, manifest present/absent, a missing develop-mode
## sibling) and asserts:
##
##   * Every FAILING check carries a NON-EMPTY remedy command
##     (Interactive-UX Principle 2 — falsifiable: an "all-green" or a
##     remedy-less failure breaks this).
##   * The expected layer names are all reported (install-version,
##     daemon-mode, store, direnv, workspace, manifest, siblings,
##     vcs-host-auth, push-gateway, toolchain, certificate-policy).
##   * The ``workspace`` check is ``fail`` with a remedy when the marker
##     is absent, and ``ok`` when present — falsifiable on the actual
##     marker state.
##   * The ``siblings`` check is ``fail`` and names a missing checkout
##     with a clone remedy when a declared repo is not cloned, ``ok``
##     when all are present.
##   * ``--json`` is valid JSON with the documented shape and a non-zero
##     exit code when any check fails; the table mode exits non-zero too.
##   * With real direnv installed, its initially untrusted, allowed and
##     denied states produce fail/ok/fail for this workspace's direnv row.
##     The allow-list is isolated under a temporary XDG_DATA_HOME; no
##     executable or status response is mocked.
##
## Skip rule: only when ``git`` is missing from PATH (same convention as
## the M9–M12 / status fixtures).

import std/[json, options, os, osproc, strutils, tables, tempfiles,
  times, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_resources          # the lease-reaper row's fixture store

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

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA30 Tester\"")
  writeFile(workPath / "README.md", "RA30 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " &
    branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))

proc projectTomlWith2Remotes(libAUrl, libBUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
mainline = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libBOrigin: string

proc setupFixture(gitBin, slug: string; withManifest: bool): Fixture =
  result.scratch = createTempDir("repro-ra30-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libBOrigin = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")
  discard seedGitOrigin(gitBin, result.libBOrigin,
    result.scratch / "seed-lib-b")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  # The ``.repro/`` SHELL, in BOTH states, so the only thing that differs
  # between them is the one thing the cases below vary: the manifests.
  #
  # It used to be absent from both, which made the "marker present" fixture a
  # bare clone of the workspace repo rather than an initialized workspace —
  # manifest-shaped directories and nothing else — and the case then asserted
  # that shape IS the marker. It is not, and the cost of reading it that way
  # was measured in the field: the lock RECORD STORE has exactly that shape
  # (``projects/``, ``repos/``, ``locks/``, no ``.repro/``), so it too was
  # classified as an initialized workspace, every "not a workspace" guard was
  # skipped there, and the pre-push gate exited 1 in a repo with nothing to
  # gate. ``hasResolvedManifestCheckout`` now requires the shell for the flat
  # layout, which is what its own contract always said. Creating it here keeps
  # this case testing what its name claims — manifest presence drives ok vs
  # fail — over a fixture that is a workspace root rather than a clone of one.
  createDir(workspaceRoot / ".repro")
  if withManifest:
    let manifestsRoot = workspaceRoot
    createDir(manifestsRoot / "projects")
    createDir(manifestsRoot / "repos")
    writeFile(manifestsRoot / "projects" / "lib-a.toml",
      projectTomlWith2Remotes(
        fileUrl(result.libAOrigin), fileUrl(result.libBOrigin)))
    writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
    writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  result.workspaceRoot = workspaceRoot

proc invokeHealth(fx: Fixture; extra: openArray[string] = []): CmdResult =
  var argv = @[
    fx.reproBin, "health", "lib-a",
    "--workspace-root=" & fx.workspaceRoot,
  ]
  for x in extra: argv.add(x)
  runShell(shellCommand(argv))

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  return nil

suite "RA-30 — repro health reports each layer status with remedy":

  test "test_ra30_every_failing_check_carries_a_remedy_command":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # Manifest present, but ZERO repos cloned: workspace marker present
      # (manifest checkout resolves it), siblings all missing → fail.
      let fx = setupFixture(gitBin, "remedy", withManifest = true)
      defer: removeDir(fx.scratch)

      let res = invokeHealth(fx, ["--json"])
      let report = parseJson(res.output)

      # Principle 2: every fail row MUST pair with a non-empty remedy.
      var sawFailure = false
      for entry in report["checks"]:
        if entry["status"].getStr() == "fail":
          sawFailure = true
          check entry["remedy"].getStr().len > 0
      check sawFailure  # the fixture is engineered to produce >=1 fail

      # JSON shape + non-zero exit on failure.
      check report["ok"].getBool() == false
      check report["failed"].getInt() >= 1
      check report["exitCode"].getInt() == 1
      check res.code == 1

      let direnvBin = findExe("direnv")
      if direnvBin.len > 0:
        let hadDataHome = existsEnv("XDG_DATA_HOME")
        let previousDataHome = getEnv("XDG_DATA_HOME")
        putEnv("XDG_DATA_HOME", fx.scratch / "direnv-data")
        defer:
          if hadDataHome: putEnv("XDG_DATA_HOME", previousDataHome)
          else: delEnv("XDG_DATA_HOME")
        writeFile(fx.workspaceRoot / ".envrc", "# real direnv trust fixture\n")
        let untrusted = parseJson(invokeHealth(fx, ["--json"]).output)
        check findCheck(untrusted, "direnv")["status"].getStr() == "fail"
        let allow = runCmd(q(direnvBin) & " allow " & q(fx.workspaceRoot))
        check allow.code == 0
        let trusted = parseJson(invokeHealth(fx, ["--json"]).output)
        check findCheck(trusted, "direnv")["status"].getStr() == "ok"
        let deny = runCmd(q(direnvBin) & " deny " & q(fx.workspaceRoot))
        check deny.code == 0
        let denied = parseJson(invokeHealth(fx, ["--json"]).output)
        check findCheck(denied, "direnv")["status"].getStr() == "fail"

  test "test_ra30_reports_all_expected_layer_names":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "layers", withManifest = true)
      defer: removeDir(fx.scratch)

      let res = invokeHealth(fx, ["--json"])
      let report = parseJson(res.output)

      for name in ["install-version", "daemon-mode", "lease-reaper", "store",
          "direnv", "workspace", "manifest", "siblings", "vcs-host-auth",
          "push-gateway", "toolchain", "certificate-policy",
          "workspace-ergonomics"]:
        check not findCheck(report, name).isNil

  test "test_ra30_workspace_marker_drives_ok_vs_fail":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # No manifest, no marker → workspace check FAILS with a remedy.
      let fxAbsent = setupFixture(gitBin, "marker-absent",
        withManifest = false)
      defer: removeDir(fxAbsent.scratch)
      block:
        let res = invokeHealth(fxAbsent, ["--json"])
        let report = parseJson(res.output)
        let ws = findCheck(report, "workspace")
        check not ws.isNil
        check ws["status"].getStr() == "fail"
        check ws["remedy"].getStr().len > 0

      # Manifest present → marker resolved → workspace check is OK.
      let fxPresent = setupFixture(gitBin, "marker-present",
        withManifest = true)
      defer: removeDir(fxPresent.scratch)
      block:
        let res = invokeHealth(fxPresent, ["--json"])
        let report = parseJson(res.output)
        let ws = findCheck(report, "workspace")
        check not ws.isNil
        check ws["status"].getStr() == "ok"

  test "test_ra30_missing_sibling_fails_with_clone_remedy_present_passes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # lib-a cloned, lib-b missing → siblings FAILS, names lib-b, has a
      # clone-style remedy.
      let fx = setupFixture(gitBin, "siblings", withManifest = true)
      defer: removeDir(fx.scratch)
      cloneInto(gitBin, fx.libAOrigin, fx.workspaceRoot / "lib-a")

      block missing:
        let res = invokeHealth(fx, ["--json"])
        let report = parseJson(res.output)
        let sib = findCheck(report, "siblings")
        check not sib.isNil
        check sib["status"].getStr() == "fail"
        check "lib-b" in sib["detail"].getStr()
        check sib["remedy"].getStr().len > 0
        check sib["fixable"].getBool() == true

      # Now clone lib-b too → siblings becomes OK.
      cloneInto(gitBin, fx.libBOrigin, fx.workspaceRoot / "lib-b")
      block present:
        let res = invokeHealth(fx, ["--json"])
        let report = parseJson(res.output)
        let sib = findCheck(report, "siblings")
        check not sib.isNil
        check sib["status"].getStr() == "ok"

  test "test_ra30_manifest_absent_fails":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-manifest", withManifest = false)
      defer: removeDir(fx.scratch)
      let res = invokeHealth(fx, ["--json"])
      let report = parseJson(res.output)
      let man = findCheck(report, "manifest")
      check not man.isNil
      check man["status"].getStr() == "fail"
      check man["remedy"].getStr().len > 0

  test "test_ra30_lease_reaper_row_reports_a_reaper_that_never_worked":
    ## The `lease-reaper` row of CLI/health.md §Checks, driven through the real
    ## binary over real on-disk state.
    ##
    ## WHY THIS ROW EXISTS. The per-user daemon's lease reap tick raised on its
    ## first record on every one of 131,882 consecutive attempts over 57 days
    ## and reaped nothing, EVER, while `daemon-mode` reported `ok` throughout
    ## and every command depending on the reaper succeeded. Nothing anywhere
    ## said "the reaper has never worked" (reprobuild-pm/issues/
    ## 2026-09-29-lease-reap-tick-has-never-once-succeeded.md, "Why it
    ## matters").
    ##
    ## TWO ENV OVERRIDES, both load-bearing for determinism:
    ##
    ##   * `HOME` points at the fixture, so the user-scope store the row reads
    ##     is the fixture's. This case must not read, and must not write, the
    ##     developer's real `~/.cache/repro/state`.
    ##   * `REPRO_DAEMON_ENDPOINT` points at a path with no socket, so the
    ##     daemon probe deterministically answers "not running". Without it the
    ##     verdict-absent-but-records-present arm would depend on whether a
    ##     daemon happens to be up on the host — it reports `fail` with a
    ##     daemon and `warn` without one, since a running daemon's tick OUGHT
    ##     to have written a verdict.
    ##
    ## NOT COVERED HERE: that same arm's `fail` side, which needs a live daemon
    ## answering the RBUD handshake. Starting one from a test is exactly how the
    ## ten leaked daemons cited in the issue above came to exist, so it is
    ## verified by hand instead and recorded in the change's report rather than
    ## risked here.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a git fixture workspace to run " &
        "`repro health` against")
    else:
      let fx = setupFixture(gitBin, "lease-reaper", withManifest = true)
      defer: removeDir(fx.scratch)

      let fixtureHome = fx.scratch / "home"
      let leaseStore = fixtureHome / ".cache" / "repro" / "state"
      let verdict = leaseStore / "reap-health"
      let deadEndpoint = fx.scratch / "no-such-daemon.sock"

      proc runHealth(extra: openArray[string] = []): CmdResult =
        var argv = @[fx.reproBin, "health", "lib-a",
          "--workspace-root=" & fx.workspaceRoot]
        for x in extra: argv.add(x)
        runShell(shellCommand(argv,
          @[(name: "HOME", value: fixtureHome),
            (name: "REPRO_DAEMON_ENDPOINT", value: deadEndpoint)]))

      proc healthWithFixtureHome(): JsonNode =
        parseJson(runHealth(["--json"]).output)

      proc leaseTextLine(extra: openArray[string] = []): string =
        ## The `lease-reaper` row as the human table renders it — the only
        ## place the DIGEST is observable, since `--json` carries the full
        ## list in `detail` and the digest in `digest`.
        for line in runHealth(extra).output.splitLines:
          if line.startsWith("lease-reaper"):
            return line
        ""

      proc leaseRow(): JsonNode =
        let row = findCheck(healthWithFixtureHome(), "lease-reaper")
        check not row.isNil
        row

      # An expired record, written the way the store itself writes one, for the
      # arms that need the store to hold something.
      proc seedRecord() =
        createDir(leaseStore)
        let store = openStateStore(leaseStore)
        writeStateRecord(store, ResourceStateRecord(
          address: "nic0",
          typeId: "vm_harness.nic",
          determinism: rdVolatile,
          attrsTypeId: "vm_harness.nic",
          attrsJson: "\x01\x00\x00\x00\x00\x00",
          dependsOn: @[],
          identity: "incus:nic0",
          present: true,
          holders: initTable[string, Time](),
          effectiveDeadline: some(getTime() - initDuration(hours = 1)),
          lastRenewed: getTime() - initDuration(hours = 1)))

      # ── No verdict, and no store at all. Genuinely nothing leased here, and
      # that must read `ok`: a doctor that is yellow by default stops being
      # read. (The fixture HOME is fresh, so there is no store yet.)
      block storeAbsent:
        check not dirExists(leaseStore)
        let row = leaseRow()
        check row["status"].getStr() == "ok"
        check row["detail"].getStr().contains("no user-scoped lease store")

      # ── No verdict, store present but EMPTY. Nothing is accumulating, so
      # still `ok` — but by a different sentence, which is what shows the row
      # looked rather than assumed.
      block storeEmpty:
        createDir(leaseStore)
        let row = leaseRow()
        check row["status"].getStr() == "ok"
        check row["detail"].getStr().contains("holds no resource records")

      # ── No verdict, store HOLDS RECORDS. This is the residual form of the
      # invisibility the row exists to remove: a tick that is stuck AND cannot
      # write its verdict leaves nothing to read, and "no verdict therefore
      # nothing leased here" would call that healthy without looking. With no
      # daemon running it is a `warn` (no-daemon is a supported path — §4.3
      # makes the store, not the daemon, the source of truth) but it must not
      # be `ok`.
      block recordsButNoVerdict:
        seedRecord()
        check not fileExists(verdict)
        let row = leaseRow()
        check row["status"].getStr() == "warn"
        check row["detail"].getStr().contains("NO reap tick has reported")
        check row["detail"].getStr().contains("1 resource record")
        check row["detail"].getStr().contains("No user daemon is running")
        # Principle 2 binds a warn that names a problem, too.
        check row["remedy"].getStr().contains("reap --once")

      # ── Ticks are running and succeeding. `ok`, with numbers — so the
      # unhealthy arm below cannot pass merely by differing from arm 1.
      block healthy:
        writeFile(verdict,
          "lastTickUnix=1791900000\n" &
          "lastSuccessUnix=1791899900\n" &
          "totalTicks=1200\n" &
          "consecutiveUnsuccessful=0\n" &
          "elidedStuck=0\n")
        let row = leaseRow()
        check row["status"].getStr() == "ok"
        check row["detail"].getStr().contains("1200 ticks recorded")
        check row["detail"].getStr().contains("last completed a sweep")
        # Not "never" — the discriminator the unhealthy arm turns on.
        check not row["detail"].getStr().contains("NEVER")

      # ── The issue's own state: past the threshold, and no sweep has EVER
      # completed.
      block neverSucceeded:
        writeFile(verdict,
          "lastTickUnix=1791900000\n" &
          "lastSuccessUnix=0\n" &
          "totalTicks=131882\n" &
          "consecutiveUnsuccessful=131882\n" &
          "elidedStuck=3\n" &
          "stuck.0=cannot reap address=nic0 typeId=vm_harness.nic: no " &
          "attribute marshaller registered for resource typeId " &
          "'vm_harness.nic'\n")
        let report = healthWithFixtureHome()
        let row = findCheck(report, "lease-reaper")
        check row["status"].getStr() == "fail"
        # "has NEVER completed a sweep" is the sentence the issue needed and
        # nothing could say. Because an IDLE tick counts as a success, it means
        # the first recorded tick already failed — a wiring fault, which is a
        # different diagnosis from a reaper that stopped working, and a bare
        # count cannot tell them apart.
        check row["detail"].getStr().contains("has NEVER completed a sweep")
        check row["detail"].getStr().contains("131882 consecutive ticks")
        # It names the stuck record, so the finding is actionable without
        # opening the daemon log...
        check row["detail"].getStr().contains("vm_harness.nic")
        check row["detail"].getStr().contains("address=nic0")
        # ...and ADMITS to what the VERDICT never recorded. That is the tick's
        # persistence cap, which is a different elision from the row's digest
        # (exercised below) and survives `--json`, because nothing can recover
        # findings the verdict did not store.
        check row["detail"].getStr().contains(
          "+3 more not recorded by the tick")
        # Interactive-UX Principle 2: a failing row carries a remedy, and it
        # names the store it applies to (the default root is not the only one).
        check row["remedy"].getStr().contains("reap --once")
        check row["remedy"].getStr().contains("--state-root=")
        # Not auto-remediated: clearing it destroys real infrastructure or
        # deletes the record naming it, and a doctor may do neither unasked.
        check row["fixable"].getBool() == false
        # A fail row must fail the command, or CI and agents cannot gate on it.
        check report["ok"].getBool() == false

      # ── The store cannot be read at all. Neither what it holds nor whether
      # it is reaped can be established, and saying `ok` here would be the
      # row answering a question it did not look at.
      block storeUnreadable:
        removeFile(verdict)
        when defined(posix):
          setFilePermissions(leaseStore, {})
          defer: setFilePermissions(leaseStore,
            {fpUserRead, fpUserWrite, fpUserExec})
          let row = leaseRow()
          check row["status"].getStr() == "fail"
          check row["detail"].getStr().contains("could not be read")
          check row["remedy"].getStr().len > 0

      # ── The digest convention (CLI/health.md §Modes): in default text mode a
      # list longer than five is summarized; `--verbose` and `--json` keep all
      # of it. Eight recorded findings, so the digest must name five and admit
      # to three.
      block digestAndVerbose:
        var verdictBody = "lastTickUnix=1791900000\n" &
          "lastSuccessUnix=0\n" &
          "totalTicks=400\n" &
          "consecutiveUnsuccessful=400\n" &
          "elidedStuck=2\n"
        for i in 0 ..< 8:
          verdictBody.add("stuck." & $i &
            "=cannot reap address=rec" & $i & " typeId=t.stuck" & $i &
            ": no attribute marshaller registered\n")
        writeFile(verdict, verdictBody)

        # DEFAULT TEXT MODE: digested at five, with `(+3 more)`.
        let digested = leaseTextLine()
        check digested.len > 0
        check digested.contains("address=rec0")
        check digested.contains("address=rec4")
        check digested.contains("(+3 more)")
        # The 6th..8th are elided from this line — that is the property.
        check not digested.contains("address=rec5")
        check not digested.contains("address=rec7")
        # BOTH elisions are stated, and they are not the same number: three
        # recorded-but-not-shown, two never recorded at all. A row that
        # reported only one of them would let the line claim completeness
        # about a verdict that was already truncated.
        check digested.contains("+2 more not recorded by the tick")

        # VERBOSE TEXT MODE: every RECORDED finding, no digest...
        let verbose = leaseTextLine(["--verbose"])
        check verbose.contains("address=rec0")
        check verbose.contains("address=rec5")
        check verbose.contains("address=rec7")
        check not verbose.contains("(+3 more)")
        # ...but the tick's own cap is still reported, because `--verbose`
        # cannot recover what was never written.
        check verbose.contains("+2 more not recorded by the tick")

        # `-v` is the same mode.
        let shortVerbose = leaseTextLine(["-v"])
        check shortVerbose.contains("address=rec7")
        check not shortVerbose.contains("(+3 more)")

        # JSON: `detail` is the FULL list and `digest` carries the summary,
        # which is the `detail`/`fullDetail` pairing `toJsonNode` renders.
        let row = findCheck(healthWithFixtureHome(), "lease-reaper")
        check row["status"].getStr() == "fail"
        check row["detail"].getStr().contains("address=rec7")
        check not row["detail"].getStr().contains("(+3 more)")
        check row.hasKey("digest")
        check row["digest"].getStr().contains("(+3 more)")
        check not row["digest"].getStr().contains("address=rec7")
