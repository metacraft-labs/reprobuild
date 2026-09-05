## One glibc reaches a dev-shell subprocess.
##
## The dev shell does not only put programs on `PATH`. It puts LOADER STATE
## into every process started inside it, and loader state is process-global: it
## applies to binaries the shell neither built nor provides. There are two such
## channels in this repository and they are independent of each other:
##
##   A. `LD_LIBRARY_PATH`, exported by `flake.nix`'s devShell so that Nim's
##      `{.dynlib.}` bindings can `dlopen` clingo / zstd / OpenSSL / pcre by
##      bare soname. It is consulted BEFORE any DT_RUNPATH, so a library from
##      this list shadows the copy a foreign binary was linked against.
##
##   B. `LD_PRELOAD` of `build/lib/librepro_monitor_shim.so`, which automatic
##      monitoring injects into every process a build action starts. The shim
##      is a DSO with its own DT_RUNPATH, so ITS `libm` / `librt` / `libdl` /
##      `libpthread` come from the shell's glibc no matter what the program
##      being monitored links against.
##
## Both put the shell's glibc into a process whose `libc.so.6` may be another
## one, and glibc's satellite libraries carry symbol-version requirements an
## older `libc.so.6` cannot satisfy. What that cost, measured on the host this
## file was written on, where `git` came from an ambient `~/.nix-profile`
## (glibc-2.40-66) and the shell's libraries from the flake's nixpkgs
## (glibc-2.42-61):
##
##   channel A:  git-remote-https: .../glibc-2.40-66/lib/libc.so.6: version
##               `GLIBC_ABI_DT_X86_64_PLT' not found (required by
##               .../glibc-2.42-61/lib/libdl.so.2)
##               fatal: remote helper 'https' aborted session
##
##   channel B:  git: .../glibc-2.40-66/lib/libc.so.6: version
##               `GLIBC_ABI_DT_X86_64_PLT' not found (required by
##               .../glibc-2.42-61/lib/libm.so.6)
##
## — so no fetch, clone or PUSH over https worked from the dev shell (channel
## A), and `repro build '.#test#<name>'`, the loop for iterating on one test
## at a time, could not run ANY git-using test, because the first
## `git init` inside a monitored `test_execute` action could not start
## (channel B). Every remote this workspace declares is `https://`.
##
## The four cases below are deliberately of three different kinds, because a
## single one of them would be a weak gate:
##
##   1. BEHAVIOURAL, offline. Start `git` and `git-remote-https` under each
##      channel and require them to start. This is the mechanism, with no
##      network in the way.
##   2. BEHAVIOURAL, online. A real https fetch that moves a real ref.
##   3. NEGATIVE, synthetic. Put a second glibc on the loader path in front of
##      a tool built against another one and require `check_dev_shell_env.sh`
##      to REFUSE, naming both store paths. This is the case that keeps its
##      value when the pins move: a gate asserting only "a fetch worked once"
##      passes on any host with a compatible pair and stops describing the
##      invariant the moment one side of it changes.
##   4. INTEGRATION. Drive a GIT-USING test through
##      `repro build '.#test#<name>'` — the loop channel B took away.
##
## What is exercised here is real: the real `git` on this shell's PATH, the
## real monitor shim, real glibc ELF files out of the nix store read with
## `patchelf` / `readelf`, and the real check script driven by `bash`. No
## process, filesystem or loader boundary is stubbed.
##
## Mocks, and why (per the repository policy on justifying every mock): NONE.
## Case 3 FABRICATES its subject — it copies a real ELF executable and rewrites
## its PT_INTERP to a real, different glibc already in the store, and copies a
## real shared object and rewrites its RUNPATH — but nothing is simulated: the
## resulting files are exactly the kind of pair the defect is made of, and the
## check reads them the same way it reads the shell's own. Fabricating the pair
## is what makes the case independent of whichever glibcs a given host's
## ambient profile happens to carry; asserting against the host's own pair
## would make this a test of that host.
##
## Skip rules, each announced:
##   * not Linux — these channels are linux-only (dyld ignores
##     DYLD_LIBRARY_PATH for anything in a protected location, and this
##     repository's darwin binaries carry LC_RPATHs instead).
##   * `patchelf` / `readelf` / `bash` / `git` missing from PATH.
##   * case 2 only: the network is unreachable. Distinguished from the defect
##     BY CONSTRUCTION rather than by classifying an error string — the same
##     fetch is run first with the loader injections REMOVED, and only a host
##     where THAT also fails is called offline.
##   * case 4 only: `build/bin/repro` not built.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support

const
  # A git-using test that reproduces channel B: its first act is `git init`.
  GitUsingTest = "t_is_published_accepts_any_remote_name"
  GlibcVersionErrorNeedle = "version `GLIBC_"

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc checkScript(): string = repoRoot() / "scripts" / "check_dev_shell_env.sh"
proc libScript(): string =
  repoRoot() / "scripts" / "lib" / "dev_shell_overrides.sh"

proc toolOnPath(name: string): string = findExe(name)

proc haveElfTools(): bool =
  toolOnPath("patchelf").len > 0 and toolOnPath("readelf").len > 0 and
    toolOnPath("bash").len > 0

proc exportedLoaderPath(): string = getEnv("LD_LIBRARY_PATH")

proc shimPath(): string = monitorShimPath(repoRoot())

proc runWithEnv(args: seq[string]; overrides: seq[(string, string)];
                cwd: string): CmdResult =
  runShell(shellCommand(args, overrides), cwd)

## --- bash-library bridge ---------------------------------------------------
##
## The version tables the negative case needs are computed by the SAME
## functions the gate uses, driven through bash, rather than reimplemented in
## Nim. A second implementation here could agree with the ELF files while
## disagreeing with the gate, which is the one thing this file must not do.
proc bashLib(fn: string; arg: string): seq[string] =
  let cmd = "set -u; source " & libScript().quoteShell & "; " &
    fn & " " & arg.quoteShell
  let res = runShell(shellCommand(@[toolOnPath("bash"), "-c", cmd]))
  for line in res.output.splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0: result.add(trimmed)

iterator storeGlibcPrefixes(): string =
  ## Every `/nix/store/<hash>-glibc-<version>` on this machine that has a
  ## `lib/libc.so.6`.
  ##
  ## The `-glibc-<digit>` shape is not cosmetic and must stay in step with
  ## `_dev_shell_glibc_prefixes` in `scripts/lib/dev_shell_overrides.sh`, which
  ## recognises exactly that. Relaxing it here to a bare `-glibc-` picks up
  ## `bootstrap-stage0-glibc-bootstrapFiles` — a real libc, with real satellite
  ## libraries requiring `GLIBC_2.0`, that a modern libc genuinely cannot
  ## satisfy — so this proc happily hands back a "conflicting pair" that the
  ## gate is right to ignore, and the case then fails against a correct gate.
  ## `getent-glibc-…` / `locale-glibc-…` are excluded by the `lib/libc.so.6`
  ## requirement.
  let store = "/nix/store"
  if dirExists(store):
    for kind, path in walkDir(store):
      if kind != pcDir: continue
      let name = path.extractFilename
      let marker = name.find("-glibc-")
      if marker < 0: continue
      let versionStart = marker + len("-glibc-")
      if versionStart >= name.len or name[versionStart] notin {'0' .. '9'}:
        continue
      if fileExists(path / "lib" / "libc.so.6"): yield path

type GlibcPair = object
  older*: string
  newer*: string
  missing*: seq[string]
  examined*: int    ## store glibcs considered
  readable*: int    ## …of which the gate's own extractor could read

proc findIncompatibleGlibcPair(): GlibcPair =
  ## A real pair (older, newer) where `older`'s `libc.so.6` does NOT define a
  ## symbol version `newer`'s satellite libraries require — i.e. exactly the
  ## shape that kills a process which ends up with both.
  var prefixes: seq[string] = @[]
  for p in storeGlibcPrefixes(): prefixes.add(p)
  var defined: seq[seq[string]] = @[]
  var required: seq[seq[string]] = @[]
  for p in prefixes:
    defined.add(bashLib("dev_shell_glibc_defined_versions", p))
    required.add(bashLib("dev_shell_glibc_required_versions", p))

  result.examined = prefixes.len
  for versions in defined:
    if versions.len > 0: inc result.readable

  for i in 0 ..< prefixes.len:
    if defined[i].len == 0: continue
    for j in 0 ..< prefixes.len:
      if i == j: continue
      var missing: seq[string] = @[]
      for want in required[j]:
        if want notin defined[i]: missing.add(want)
      if missing.len > 0:
        result.older = prefixes[i]
        result.newer = prefixes[j]
        result.missing = missing
        return

suite "dev shell — one glibc reaches a subprocess":

  test "git and its https helper start under both loader-injection channels":
    when not defined(linux):
      checkpoint("skipped — LD_LIBRARY_PATH / LD_PRELOAD injection is " &
        "linux-only; on " & hostOS & " this repository's binaries carry " &
        "LC_RPATHs instead")
      skip()
    else:
      let git = toolOnPath("git")
      if git.len == 0:
        checkpoint("skipped — no git on PATH")
        skip()
      else:
        # The helper is the binary that actually died: it lives under
        # `git --exec-path`, not on PATH, and `git` itself starting says
        # nothing about it (that is what made the defect look like a network
        # problem for as long as it did).
        let execPath = execProcess(git, args = ["--exec-path"],
          options = {poUsePath}).strip()
        let helper = execPath / "git-remote-https"
        check fileExists(helper)

        var channels: seq[(string, seq[(string, string)])] = @[]
        let exported = exportedLoaderPath()
        if exported.len > 0:
          channels.add(("LD_LIBRARY_PATH", @[("LD_LIBRARY_PATH", exported)]))
        else:
          checkpoint("channel A not exercised — this environment exports no " &
            "LD_LIBRARY_PATH (a nix build sandbox / bare CI shell); the " &
            "channel does not exist here to be wrong about")
        if fileExists(shimPath()):
          channels.add(("LD_PRELOAD monitor shim",
            @[("LD_PRELOAD", shimPath())]))
        else:
          checkpoint("channel B not exercised — " & shimPath() &
            " is not built; run `just build` for the monitored-action channel")

        if channels.len == 0:
          checkpoint("skipped — neither injection channel exists in this " &
            "environment, so there is nothing here that could be wrong")
          skip()
        else:
          for (name, env) in channels:
            let version = runWithEnv(@[git, "--version"], env, getCurrentDir())
            checkpoint(name & ": git --version -> exit " & $version.code &
              ": " & version.output.strip())
            check GlibcVersionErrorNeedle notin version.output
            check version.code == 0

            # The helper refuses to run outside git (it wants a remote on
            # argv), so its EXIT CODE is not the signal — whether it got far
            # enough to complain is. A loader failure never reaches that point.
            let helperRun = runWithEnv(@[helper], env, getCurrentDir())
            checkpoint(name & ": git-remote-https -> exit " &
              $helperRun.code & ": " & helperRun.output.strip())
            check GlibcVersionErrorNeedle notin helperRun.output

  test "git fetch over https moves a remote-tracking ref in this shell":
    when not defined(linux):
      checkpoint("skipped — see the first case; injection is linux-only")
      skip()
    else:
      let git = toolOnPath("git")
      if git.len == 0:
        checkpoint("skipped — no git on PATH")
        skip()
      else:
        let originUrl = execProcess(git,
          args = ["-C", repoRoot(), "remote", "get-url", "origin"],
          options = {poUsePath}).strip()
        if not originUrl.startsWith("https://"):
          checkpoint("skipped — this checkout's origin is " & originUrl &
            ", not an https remote; the https transport is what this case " &
            "is about")
          skip()
        else:
          let scratch = createTempDir("repro-dev-shell-https-", "")
          defer: removeDirEventually(scratch)
          discard requireSuccess(shellCommand(
            @[git, "init", "-q", "-b", "main", scratch]))
          discard requireSuccess(shellCommand(
            @[git, "-C", scratch, "remote", "add", "origin", originUrl]))

          let fetchArgs = @[git, "-C", scratch, "fetch", "--depth=1",
            "origin", "HEAD"]

          # Offline is separated from broken BY CONSTRUCTION, not by matching
          # an error string: run the same fetch with the shell's loader
          # injections removed. If THAT cannot reach the remote either, the
          # host has no network and this case has nothing to say. If it can,
          # any failure of the injected run is the defect.
          let clean = runWithEnv(fetchArgs, @[("LD_LIBRARY_PATH", "")],
            getCurrentDir())
          if clean.code != 0:
            checkpoint("skipped — the remote is unreachable even with the " &
              "loader injections removed, so this host is offline rather " &
              "than broken:\n" & clean.output)
            skip()
          else:
            let injected = runShell(shellCommand(fetchArgs))
            if injected.code != 0:
              checkpoint(injected.output)
            check GlibcVersionErrorNeedle notin injected.output
            check "remote helper" notin injected.output
            check injected.code == 0
            # "exits 0" is not the assertion; a ref that moved is.
            let head = runShell(shellCommand(
              @[git, "-C", scratch, "rev-parse", "FETCH_HEAD"]))
            check head.code == 0
            check head.output.strip().len == 40

  test "the check refuses a second glibc on the loader path, naming both":
    when not defined(linux):
      checkpoint("skipped — see the first case; injection is linux-only")
      skip()
    else:
      if not haveElfTools():
        checkpoint("skipped — patchelf, readelf and bash are all required " &
          "to build and read the fabricated pair")
        skip()
      else:
        let pair = findIncompatibleGlibcPair()
        checkpoint("store glibcs examined: " & $pair.examined &
          ", version tables the gate's own extractor could read: " &
          $pair.readable)
        if pair.examined > 0 and pair.readable == 0:
          # A FAILURE, not a skip, and the distinction is the whole point: an
          # extractor that reads nothing out of every real glibc on the machine
          # is broken, and "no conflicting pair could be built here" is exactly
          # how that would present. Measured while writing this file — binutils
          # writes the section heading as "Version definition section" while
          # the extractor looked for "Version definitions section" — and a skip
          # would have carried it. Nothing below is meaningful in this state, so
          # the case stops here rather than skipping into a green run.
          checkpoint("scripts/lib/dev_shell_overrides.sh could not read the " &
            "symbol-version table of ANY of the " & $pair.examined &
            " glibcs in /nix/store. dev_shell_glibc_defined_versions is " &
            "broken against the readelf on this PATH; the gate that uses it " &
            "cannot distinguish a compatible pair from an incompatible one.")
          fail()
        elif pair.older.len == 0:
          checkpoint("skipped — this machine's /nix/store holds no two " &
            "glibcs where one fails to define a symbol version the other " &
            "requires, so the conflict this case is about cannot be built " &
            "here out of real files")
          skip()
        else:
          checkpoint("fabricating from real store paths: older=" &
            pair.older & " newer=" & pair.newer & " missing=" &
            pair.missing.join(","))
          let tempRoot = createTempDir("repro-dev-shell-glibc-", "")
          defer: removeDirEventually(tempRoot)
          # One level of nesting on purpose. `check_dev_shell_env.sh` resolves
          # the auto-override arm's siblings as `dirname($REPO_ROOT)/*`, so a
          # tree placed directly in `$TMPDIR` treats every scratch directory on
          # the machine as a workspace sibling and reports whichever of them
          # happens to share a name with a flake input. That is noise from
          # another check, and noise is how a real finding gets missed.
          let scratch = tempRoot / "workspace" / "repo"
          createDir(scratch / "scripts" / "lib")
          copyFile(checkScript(), scratch / "scripts" /
            "check_dev_shell_env.sh")
          copyFile(libScript(), scratch / "scripts" / "lib" /
            "dev_shell_overrides.sh")
          copyFile(repoRoot() / ".envrc", scratch / ".envrc")
          copyFile(repoRoot() / "flake.nix", scratch / "flake.nix")
          copyFile(repoRoot() / "scripts" / "dev-shell-pinned-siblings.tsv",
            scratch / "scripts" / "dev-shell-pinned-siblings.tsv")

          # The injected library: a real shared object whose RUNPATH names the
          # newer glibc, which is exactly what every entry on this shell's
          # LD_LIBRARY_PATH looks like.
          let injectDir = scratch / "inject"
          createDir(injectDir)
          let probeLib = injectDir / "libf05probe.so"
          copyFile(pair.newer / "lib" / "libm.so.6", probeLib)
          setFilePermissions(probeLib, {fpUserRead, fpUserWrite, fpUserExec})
          discard requireSuccess(shellCommand(@[toolOnPath("patchelf"),
            "--set-rpath", pair.newer / "lib", probeLib]))

          # The tool: a real dynamic ELF that runs on the OLDER glibc, placed
          # first on PATH under the name the gate looks for.
          let fakeBin = scratch / "bin"
          createDir(fakeBin)
          let donor = toolOnPath("true")
          check donor.len > 0
          proc loaderIn(glibc: string): string =
            ## The interpreter's basename is architecture-specific
            ## (`ld-linux-x86-64.so.2`, `ld-linux-aarch64.so.1`, …), so take
            ## whichever one the glibc actually ships rather than naming one.
            ## Only its store-path PREFIX is what the check reads, but a path
            ## that exists keeps the fabricated binary honest.
            for found in walkFiles(glibc / "lib" / "ld-linux-*.so.*"):
              return found
            glibc / "lib" / "ld-linux-x86-64.so.2"

          proc makeFakeGit(interp: string) =
            copyFile(donor, fakeBin / "git")
            setFilePermissions(fakeBin / "git",
              {fpUserRead, fpUserWrite, fpUserExec})
            discard requireSuccess(shellCommand(@[toolOnPath("patchelf"),
              "--set-interpreter", loaderIn(interp), fakeBin / "git"]))

          proc runCheck(): CmdResult =
            runWithEnv(@[toolOnPath("bash"),
                scratch / "scripts" / "check_dev_shell_env.sh"],
              @[("LD_LIBRARY_PATH", injectDir),
                ("PATH", fakeBin & $PathSep & getEnv("PATH"))],
              scratch)

          # NEGATIVE polarity: the tool is on the older glibc.
          makeFakeGit(pair.older)
          let refused = runCheck()
          checkpoint(refused.output)
          check refused.code != 0
          check "injects a second glibc into a program it does not provide" in
            refused.output
          # Naming BOTH store paths is the requirement: a message that says
          # only "mismatch" leaves the reader to find which two things.
          check pair.older in refused.output
          check pair.newer in refused.output
          check injectDir in refused.output
          for want in pair.missing:
            check want in refused.output
          check "one glibc reaches a subprocess" notin refused.output

          # POSITIVE polarity, same fabricated tree: move ONLY the tool's
          # interpreter to the newer glibc and the same check must accept. One
          # bit changed, both answers — which is what separates a gate from a
          # thing that always says no.
          makeFakeGit(pair.newer)
          let accepted = runCheck()
          checkpoint(accepted.output)
          check "one glibc reaches a subprocess" in accepted.output
          check "injects a second glibc" notin accepted.output

  test "engine: a git-using test runs through repro build .#test#<name>":
    let root = repoRoot()
    let reproBin = root / "build" / "bin" / addFileExt("repro", ExeExt)
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin & " is missing; run `just build`")
      skip()
    else:
      discard requireRunQuotaDaemonBin(root)
      let scratch = createTempDir("repro-dev-shell-engine-", "")
      defer: removeDirEventually(scratch)
      let reportPath = scratch / "report.json"
      let res = runShell(shellCommand(@[
        reproBin, "build", ".#test#" & GitUsingTest,
        "--tool-provisioning=path", "--daemon=off",
        "--progress=quiet", "--log=actions",
        "--write-report=" & reportPath]), root)
      if res.code != 0:
        checkpoint(res.output)
        # The engine writes an action's stdout to the failure report, not to
        # the console, and channel B's failure appears ONLY on stdout. Surface
        # it here so a red run says why rather than showing an empty stderr.
        let failureReport = root / ".repro" / "build" / "repro" /
          "build-failure-report.json"
        if fileExists(failureReport):
          checkpoint("build-failure-report.json:\n" &
            readFile(failureReport))
      check GlibcVersionErrorNeedle notin res.output
      check res.code == 0
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      # The action must have been RUN, not merely planned: the loop this case
      # restores is "the test executed", and a report that mentions the edge
      # without a status would satisfy a weaker assertion.
      let rendered = $report
      check ("test_execute." & GitUsingTest) in rendered
