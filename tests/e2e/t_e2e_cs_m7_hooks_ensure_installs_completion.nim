## e2e_cs_m7_hooks_ensure_installs_completion: `repro hooks ensure
## --shell-autocomplete` installs completion for every shell it finds, per
## user (`--profile`) and system-wide (`--system`), and a fresh shell then
## completes `repro` from what it installed.
##
## Each case runs the real `repro` (build/bin) in its own scratch directory:
## `HOME`, `USERPROFILE`, `ZDOTDIR`, the XDG directories and
## `BASH_COMPLETION_USER_DIR` point inside it, `XDG_DATA_DIRS` is the scratch
## system root's `usr/local/share:usr/share`, `PATH` holds the build's `bin`
## and a directory of links to the shells only (bash: the first on `PATH`
## that has the `complete` builtin), and `--system` always runs under
## `--system-root=<scratch>`. A guard compares the invoking user's real rc
## and completion files (hash and mtime) and the machine's
## `/usr/local/share/…/repro*` and `/etc/fish/completions/repro.fish`
## completion files before and after each case.
##
## The shells are real (bash, zsh, fish and pwsh from the dev shell) and
## started without the user's startup files (`bash --norc --noprofile -i`,
## `zsh -f -i`, `fish --no-config -i`, `pwsh -NoProfile`); each then loads
## what `repro` installed the way that shell's own startup would:
##
## * bash: bash-completion's loader (when the host has one, copied into the
##   scratch root so `repro` sees it installed), which finds the per-user or
##   `XDG_DATA_DIRS` file on demand; without it, the `~/.bashrc` block;
## * zsh: `compinit`, then the `.zshrc` block (per user), or `compinit` with
##   the root's `site-functions` on `fpath` (system-wide);
## * fish: `fish_complete_path` set to fish's documented search order (the
##   user directory, then the system configuration directory's
##   `fish/completions`, here under the scratch root, then
##   `vendor_completions.d` under each `XDG_DATA_DIRS` entry), which
##   `--no-config` leaves empty. On Linux `--system` puts fish's script in
##   `/etc/fish/completions`, because fish reads
##   `/usr/local/share/fish/vendor_completions.d` only when `XDG_DATA_DIRS`
##   names it;
## * pwsh: the profile block, dot-sourced, then `TabExpansion2`, the function
##   PowerShell's Tab key calls (no terminal needed).
##
## Then it types `repro wor<Tab>` and the like on a pseudo-terminal
## (`repro_test_support/shell_pty`) and reads back the completed line. A
## control shell with nothing installed must not complete.
##
## On Windows the per-user PowerShell profiles live under the Documents
## folder the shell API reports (`SHGetFolderPathW` in repro,
## `[Environment]::GetFolderPath('MyDocuments')` in PowerShell). Its registry
## value is normally `%USERPROFILE%\Documents`, expanded with the calling
## process's environment, so the case's redirected `USERPROFILE` moves it into
## the scratch home, for repro and for the PowerShell the case starts alike.
## The case therefore asks PowerShell for the folder IN THE CASE'S
## ENVIRONMENT (`windowsDocuments(w)`), and checks that repro wrote where that
## PowerShell reads. Only a profile that still resolves outside the scratch
## directory (a Documents folder the registry names absolutely, such as a
## redirected or synced one) is the invoking user's real file: such files are
## saved to an on-disk journal first and restored byte for byte after, on
## every exit path, and a journal left by a run that died makes the next run
## refuse to start (`repro_test_support/real_file_guard`). Each saved and
## restored file is printed on stderr; with the default registry value
## nothing is saved and no journal is written. Either way the real profiles'
## contents are compared before and after every case (`hostWatched`). Run the
## Windows legs directly, not under a home fence (`REPRO_TEST_HOME_FENCE`),
## which would refuse the writes a non-default Documents folder needs.
##
## `--system` and PowerShell's `$PSHOME`. The all-users block goes in
## `$PSHOME/profile.ps1` (`$PSHOME\Profile.ps1` on Windows), which
## `--system-root` re-roots like every other system path. The cases that
## exercise a writable and an unwritable `$PSHOME` therefore put no real
## PowerShell on the `PATH` repro searches: they lay out scratch PowerShell
## installations (`fakePowerShells`: PowerShell 7's `pwsh` beside a
## `System.Management.Automation.dll`, and on Windows also a Windows
## PowerShell 5.1 `powershell.exe` in a `WindowsPowerShell\v1.0` directory),
## files repro inspects but never starts. Before running repro such a case
## refuses to go on when its `PATH` reaches any PowerShell outside its scratch
## directory (`requireScratchPowerShells`), and afterwards it checks that
## nothing was written into the scratch installations themselves, only under
## the root: a repro that stopped re-rooting `$PSHOME` fails the case and
## still writes no real profile. On Windows every `--system` case uses such a
## `PATH`. The real all-users profiles of the machine's PowerShells are among
## the files compared before and after every case (`realPsHomeProfiles`).
##
## `REPRO_E2E_REQUIRE_SHELLS` (comma-separated: bash, zsh, fish, pwsh, and
## `bash-completion` for the loader leg) turns a missing shell into a
## failure instead of a `SKIP-LOUD` line. The test kills only the shells it
## started, by pid. Nothing is mocked.

import std/[hashes, json, os, osproc, sets, strutils, tables, times]

import std/unittest

import repro_test_support
import repro_test_support/real_file_guard
when defined(posix):
  import repro_test_support/shell_pty

const
  LineMarker = "CSM7_LINE:"
    ## What the echo a case types prints before the completed line; typed
    ## as `CS''M7_LINE:` so the echoed command line never contains it.
  EchoLine = "\x01echo CS''M7_LINE:"
    ## Ctrl-A (start of line in readline, zle and fish), then the echo.

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc required(what: string): bool =
  what in getEnv("REPRO_E2E_REQUIRE_SHELLS").split(',')

template skipLoud(what, why: string) =
  echo "SKIP-LOUD: ", what, ": ", why, "; this leg did NOT run"
  checkpoint("REPRO_E2E_REQUIRE_SHELLS=" & getEnv("REPRO_E2E_REQUIRE_SHELLS"))
  check not required(what)

# ---------------------------------------------------------------------------
# The machine this runs on must not change.
# ---------------------------------------------------------------------------

proc windowsDocuments(env: openArray[tuple[name, value: string]] = []):
    string

proc hostWatched(): seq[string] =
  ## The invoking user's real rc and completion files, and the machine's
  ## system-wide completion files for repro.
  let home = getEnv("HOME")
  result = @[]
  if home.len > 0:
    for rel in [".bashrc", ".zshrc", ".config/fish/config.fish",
        ".config/fish/completions/repro.fish",
        ".local/share/bash-completion/completions/repro",
        ".local/share/zsh/site-functions/_repro",
        ".config/powershell/profile.ps1",
        ".config/powershell/Microsoft.PowerShell_profile.ps1",
        ".local/share/repro/completions/repro.ps1"]:
      result.add(home / rel)
  for p in ["/usr/local/share/bash-completion/completions/repro",
      "/usr/local/share/zsh/site-functions/_repro",
      "/usr/local/share/fish/vendor_completions.d/repro.fish",
      "/etc/fish/completions/repro.fish",
      "/usr/local/share/repro/completions/repro.ps1"]:
    result.add(p)

proc realWindowsProfiles(): seq[string] =
  ## The invoking user's real PowerShell profiles, under the Documents folder
  ## PowerShell reports in this process's (unredirected) environment; none
  ## off Windows.
  when defined(windows):
    let docs = windowsDocuments()
    @[docs / "PowerShell" / "Profile.ps1",
      docs / "PowerShell" / "Microsoft.PowerShell_profile.ps1",
      docs / "WindowsPowerShell" / "Profile.ps1",
      docs / "WindowsPowerShell" / "Microsoft.PowerShell_profile.ps1"]
  else:
    @[]

proc realPsHomeProfiles(): seq[string] =
  ## The all-users profiles (`$PROFILE.AllUsersAllHosts`) of the machine's
  ## real PowerShells, each asked for its own `$PSHOME`.
  var exes: seq[string] = @[]
  for name in ["pwsh", "powershell"]:
    let exe = findExe(name)
    if exe.len > 0:
      exes.add(exe)
  for exe in exes:
    let res = runShell(shellCommand(@[exe, "-NoProfile", "-NonInteractive",
      "-Command", "$PSHOME"]), timeoutMs = 60_000)
    let home = res.output.strip()
    doAssert res.code == 0 and home.len > 0 and isAbsolute(home),
      exe & " did not report its $PSHOME: " & res.output
    result.add(home / (when defined(windows): "Profile.ps1"
                       else: "profile.ps1"))

proc hostState(): seq[string] =
  for p in hostWatched():
    if fileExists(p):
      result.add(p & " " & $getLastModificationTime(p).toUnix & " " &
        $hash(readFile(p)))
    else:
      result.add(p & " absent")
  # The real PowerShell profiles by content only: a leg that has to save and
  # restore one (a Documents folder outside the scratch) changes its mtime.
  var profiles {.global.}: seq[string]
  var profilesDone {.global.} = false
  if not profilesDone:
    profiles = realWindowsProfiles() & realPsHomeProfiles()
    profilesDone = true
  for p in profiles:
    if fileExists(p):
      result.add(p & " " & $hash(readFile(p)))
    else:
      result.add(p & " absent")

# ---------------------------------------------------------------------------
# The scratch world.
# ---------------------------------------------------------------------------

type
  World = object
    dir: string       ## the case's scratch
    home: string
    zdot: string      ## ZDOTDIR, apart from HOME so its use is checked
    data: string      ## XDG_DATA_HOME
    config: string    ## XDG_CONFIG_HOME
    bashUser: string  ## BASH_COMPLETION_USER_DIR
    root: string      ## --system-root
    path: string      ## PATH for repro and the shells

proc hasCompleteBuiltin(bash: string): bool =
  ## Whether `bash` is an interactive build, with readline and programmable
  ## completion: Nix's default `bash` is built without them, so it has no
  ## `complete` builtin and cannot complete anything.
  let res = runShell(shellCommand(@[bash, "-c",
    "type complete >/dev/null 2>&1 && echo CSM7_HAS_COMPLETE"]),
    timeoutMs = 20_000)
  res.code == 0 and "CSM7_HAS_COMPLETE" in res.output

proc findShells(): Table[string, string] =
  ## The shells of the invoking environment (the dev shell), by name: the
  ## first of each on PATH, and for bash the first that can complete.
  for name in ["zsh", "fish", "pwsh", "git"]:
    let exe = findExe(name)
    if exe.len > 0:
      result[name] = exe
  when defined(windows):
    # Windows PowerShell 5.1, which has profiles of its own.
    let ps = findExe("powershell")
    if ps.len > 0:
      result["powershell"] = ps
    return
  for dir in getEnv("PATH").split(PathSep):
    let bash = dir / "bash"
    if dir.len > 0 and fileExists(bash) and hasCompleteBuiltin(bash):
      result["bash"] = bash
      break

proc shells(): Table[string, string] =
  ## `findShells`, computed once per process.
  var cache {.global.}: Table[string, string]
  var done {.global.} = false
  if not done:
    cache = findShells()
    done = true
  cache

proc linkShells(binDir: string; withGit: bool) =
  ## `binDir` holds a link to each shell found (and to git for a bare
  ## `ensure`), nothing else, so the PATH repro searches holds exactly the
  ## shells this test drives, whatever else their own directories hold.
  createDir(binDir)
  when defined(windows):
    # Links need a privilege on Windows: `pathFor` names the shells' own
    # directories instead.
    return
  var names = @["bash", "zsh", "fish", "pwsh"]
  if withGit:
    names.add("git")
  for name in names:
    if name in shells():
      createSymlink(shells()[name], binDir / name)

proc pathFor(binDir: string): string =
  ## The build's `bin`, then the linked shells (on Windows, the directories
  ## of the shells and git found).
  result = parentDir(reproBinary()) & $PathSep & binDir
  when defined(windows):
    for name in ["pwsh", "powershell", "git"]:
      if name in shells():
        result.add($PathSep & parentDir(shells()[name]))

proc newWorld(name: string; withGit = false): World =
  let base = getTempDir() / ("cs_m7_completion" & testCaseScratchSlug()) /
    name
  if dirExists(base):
    removeDir(base)
  linkShells(base / "bin", withGit)
  result = World(dir: base, home: base / "home", zdot: base / "home" / "zdot",
    data: base / "home" / "data", config: base / "home" / "config",
    bashUser: base / "home" / "bcu", root: base / "root",
    path: pathFor(base / "bin"))
  for d in [result.home, result.zdot, result.data, result.config,
      result.root, base / "work", base / "cache", base / "state"]:
    createDir(d)

proc env(w: World): seq[tuple[name, value: string]] =
  @[("HOME", w.home), ("USERPROFILE", w.home), ("ZDOTDIR", w.zdot),
    ("XDG_DATA_HOME", w.data), ("XDG_CONFIG_HOME", w.config),
    ("XDG_CACHE_HOME", w.dir / "cache"), ("XDG_STATE_HOME", w.dir / "state"),
    ("BASH_COMPLETION_USER_DIR", w.bashUser),
    ("LOCALAPPDATA", w.dir / "localappdata"),
    ("XDG_DATA_DIRS", w.root / "usr/local/share" & ":" &
      w.root / "usr/share"),
    ("PATH", w.path)]

proc repro(w: World; args: openArray[string]): CmdResult =
  runShell(shellCommand(@[reproBinary()] & @args, w.env), w.dir / "work",
    timeoutMs = 120_000)

proc script(shell: string): string =
  let res = runShell(shellCommand(@[reproBinary(), "completion", shell]))
  doAssert res.code == 0, res.output
  res.output

proc entriesOf(output: string): seq[JsonNode] =
  ## The completion entries of a `--json` report on stdout.
  # stdout and stderr are merged: the document is from its first line to
  # its closing brace, whatever stderr printed around it.
  let output = output.replace("\r\n", "\n")
  let start = output.find("{\n")
  let stop = output.rfind("\n}")
  doAssert start >= 0 and stop > start, "no JSON document in:\n" & output
  let doc = parseJson(output[start .. stop + 1])
  for e in doc["entries"]:
    if e{"kind"}.getStr == "completion":
      result.add(e)

proc outcomes(entries: seq[JsonNode]): Table[string, string] =
  ## path -> outcome.
  for e in entries:
    result[e["path"].getStr] = e["outcome"].getStr

proc filesUnder(dir: string): HashSet[string] =
  for p in walkDirRec(dir):
    result.incl(p)

proc blockCount(path, shell: string): int =
  ## How many `repro-completion-<shell>` blocks `path` holds (their opening
  ## sentinel lines).
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines():
    if line.startsWith("# >>>") and
        line.contains("repro-completion-" & shell & " "):
      inc result

proc bashLoader(): string =
  ## A bash-completion loader on this machine, or "".
  let fromEnv = getEnv("REPRO_E2E_BASH_COMPLETION")
  if fromEnv.len > 0 and fileExists(fromEnv):
    return fromEnv
  for p in ["/usr/share/bash-completion/bash_completion",
      "/usr/local/share/bash-completion/bash_completion",
      "/run/current-system/sw/share/bash-completion/bash_completion"]:
    if fileExists(p):
      return p
  ""

proc installLoader(w: World): string =
  ## Copies the host's bash-completion loader into the scratch root, where
  ## `repro --system-root` looks for it; returns the copy, or "".
  let loader = bashLoader()
  if loader.len == 0:
    return ""
  result = w.root / "usr/share/bash-completion/bash_completion"
  createDir(parentDir(result))
  copyFile(loader, result)

# ---------------------------------------------------------------------------
# The documented locations, written out (not computed by the code under
# test).
# ---------------------------------------------------------------------------

proc underRoot(w: World; path: string): string =
  ## `path` re-rooted under the case's `--system-root`, its drive (on
  ## Windows) dropped, as the documentation of `--system-root` says.
  var rest = path
  if rest.len >= 2 and rest[1] == ':':
    rest = rest[2 .. ^1]
  w.root / rest.strip(trailing = false, chars = {'/', '\\'})

proc userFile(w: World; shell: string): string =
  case shell
  of "bash": w.bashUser / "completions/repro"
  of "zsh": w.data / "zsh/site-functions/_repro"
  of "fish": w.config / "fish/completions/repro.fish"
  else:
    when defined(windows): w.dir / "localappdata/repro/completions/repro.ps1"
    else: w.data / "repro/completions/repro.ps1"

proc userBlockFile(w: World; shell: string): string =
  case shell
  of "bash": w.home / ".bashrc"
  of "zsh": w.zdot / ".zshrc"
  of "powershell": w.config / "powershell/profile.ps1"
  else: ""

proc systemFile(w: World; shell: string): string =
  case shell
  of "bash": w.root / "usr/local/share/bash-completion/completions/repro"
  of "zsh": w.root / "usr/local/share/zsh/site-functions/_repro"
  of "fish":
    when defined(linux): w.root / "etc/fish/completions/repro.fish"
    else: w.root / "usr/local/share/fish/vendor_completions.d/repro.fish"
  else:
    # Windows: under the installation prefix, the directory above the
    # running binary's `bin\`, re-rooted.
    when defined(windows): underRoot(w, parentDir(parentDir(reproBinary()))) /
      "share" / "repro" / "completions" / "repro.ps1"
    else: w.root / "usr/local/share/repro/completions/repro.ps1"

proc presentShells(): seq[string] =
  ## The completion shells repro will find on `pathFor()`.
  for (exe, shell) in [("bash", "bash"), ("zsh", "zsh"), ("fish", "fish"),
      ("pwsh", "powershell"), ("powershell", "powershell")]:
    if exe in shells() and shell notin result:
      result.add(shell)

# ---------------------------------------------------------------------------
# The native shell integration (`--shell`), which a bare `ensure` installs
# for every shell found.
# ---------------------------------------------------------------------------

proc windowsDocuments(env: openArray[tuple[name, value: string]] = []):
    string =
  ## The Documents folder as Windows reports it, asked of PowerShell itself
  ## (not computed by the code under test), in this process's environment
  ## overridden by `env`; "" off Windows. Pass a case's environment
  ## (`w.env`): the folder is expanded from `%USERPROFILE%` by default, so
  ## the case's redirected `USERPROFILE` moves it, as it does for the repro
  ## and the PowerShell the case starts.
  when defined(windows):
    let ps =
      if "pwsh" in shells(): shells()["pwsh"]
      elif "powershell" in shells(): shells()["powershell"]
      else: ""
    doAssert ps.len > 0, "no PowerShell to ask for the Documents folder"
    let res = runShell(shellCommand(@[ps, "-NoProfile", "-NonInteractive",
      "-Command", "[Environment]::GetFolderPath('MyDocuments')"], env),
      timeoutMs = 60_000)
    # An empty answer would turn every profile path relative and the
    # comparisons and saves built on it into silent no-ops.
    doAssert res.code == 0 and res.output.strip().len > 0, res.output
    res.output.strip()
  else:
    ""

proc nativeRcFile(w: World; shell: string): string =
  ## Where the native block of `shell` goes (written out, not computed by
  ## the code under test).
  case shell
  of "bash": w.home / ".bashrc"
  of "zsh": w.zdot / ".zshrc"
  of "fish": w.config / "fish/config.fish"
  else:
    when defined(windows):
      windowsDocuments(w.env) / "PowerShell" /
        "Microsoft.PowerShell_profile.ps1"
    else:
      w.config / "powershell/Microsoft.PowerShell_profile.ps1"

proc nativeBlockCount(path, shell: string): int =
  ## How many native shell blocks for `shell` `path` holds.
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines():
    if line.startsWith("# >>>") and
        line.contains("repro-dev-env-native-" & shell & " "):
      inc result

proc windowsProfiles(w: World): seq[string] =
  ## The PowerShell profiles a Windows leg writes, under the Documents folder
  ## the case's environment resolves (`windowsDocuments(w.env)`), that lie
  ## OUTSIDE the case's scratch directory: real files of the invoking user,
  ## saved before and restored after the leg. With the default registry value
  ## (`%USERPROFILE%\Documents`) the folder is inside the scratch home and
  ## this is empty, so nothing real is touched or saved.
  when defined(windows):
    let docs = windowsDocuments(w.env)
    result = pathsOutside([docs / "PowerShell" / "Profile.ps1",
        docs / "WindowsPowerShell" / "Profile.ps1",
        docs / "PowerShell" / "Microsoft.PowerShell_profile.ps1"], w.dir)
  else:
    discard w
    result = @[]

proc saveFiles(paths: seq[string]): RealFilesGuard =
  ## Saves `paths` to an on-disk journal before a leg touches them; refuses
  ## to run when an earlier run left its journal (`real_file_guard`).
  saveRealFiles(paths, defaultRealFilesJournal("cs-m7-powershell-profiles"))

proc restoreFiles(saved: RealFilesGuard) =
  ## Puts every saved file back byte for byte and removes what the leg
  ## created.
  restoreRealFiles(saved)

# ---------------------------------------------------------------------------
# Scratch PowerShell installations, for `--system`.
# ---------------------------------------------------------------------------

type FakePowerShell = object
  exe: string    ## the executable repro finds on the case's PATH
  home: string   ## its $PSHOME (outside the root; repro must re-root it)

proc fakePowerShells(w: World): seq[FakePowerShell] =
  ## Scratch PowerShell installations under the case's directory, laid out
  ## as repro recognises a `$PSHOME` without starting PowerShell:
  ## PowerShell 7's `pwsh` beside `System.Management.Automation.dll`, and on
  ## Windows Windows PowerShell 5.1's `powershell.exe`, whose directory is
  ## its `$PSHOME`. The executables are never run (repro starts no shell to
  ## detect one), so they hold nothing a PowerShell would.
  let pwshHome = w.dir / "fps" / "PowerShell" / "7"
  createDir(pwshHome)
  writeFile(pwshHome / "System.Management.Automation.dll", "")
  let pwsh = pwshHome / addFileExt("pwsh", ExeExt)
  when defined(windows):
    writeFile(pwsh, "")
  else:
    writeFile(pwsh, "#!/bin/sh\nexit 1\n")
    setFilePermissions(pwsh, {fpUserRead, fpUserWrite, fpUserExec})
  result.add FakePowerShell(exe: expandFilename(pwsh),
    home: expandFilename(pwshHome))
  when defined(windows):
    let v1 = w.dir / "fps" / "WindowsPowerShell" / "v1.0"
    createDir(v1)
    writeFile(v1 / "powershell.exe", "")
    result.add FakePowerShell(exe: expandFilename(v1 / "powershell.exe"),
      home: expandFilename(v1))

proc fakePath(fakes: seq[FakePowerShell]; extra: seq[string] = @[]): string =
  ## The build's `bin`, the scratch PowerShells' directories, then `extra`.
  result = parentDir(reproBinary())
  for f in fakes:
    result.add($PathSep & parentDir(f.exe))
  for dir in extra:
    result.add($PathSep & dir)

proc requireScratchPowerShells(w: World): bool =
  ## Whether every PowerShell the case's `PATH` reaches lies inside the
  ## case's scratch directory. A `--system` case refuses to run otherwise:
  ## the all-users profile repro writes is in the `$PSHOME` of each
  ## PowerShell it finds, so with a real one on `PATH` a repro that stopped
  ## re-rooting `$PSHOME` would write the machine's real profile.
  result = true
  for dir in w.path.split(PathSep):
    if dir.len == 0:
      continue
    for name in ["pwsh", "powershell"]:
      for ext in (when defined(windows): @[".exe", ".cmd", ".bat", ""]
                  else: @[""]):
        let candidate = dir / (name & ext)
        if fileExists(candidate) and
            pathsOutside([expandFilename(candidate)], w.dir).len > 0:
          checkpoint("REFUSED: the case's PATH reaches the PowerShell " &
            candidate & ", outside the scratch " & w.dir)
          result = false

proc allUsersProfile(w: World; f: FakePowerShell): string =
  ## Where the all-users block of `f` goes: its `$PSHOME`'s profile, under
  ## the root (written out, not computed by the code under test).
  underRoot(w, f.home) / (when defined(windows): "Profile.ps1"
                          else: "profile.ps1")

proc writtenIntoFakes(fakes: seq[FakePowerShell]): seq[string] =
  ## Any profile in the scratch installations themselves, which only a repro
  ## that did not re-root `$PSHOME` writes.
  for f in fakes:
    for name in ["Profile.ps1", "profile.ps1"]:
      if fileExists(f.home / name):
        result.add(f.home / name)

proc samePath(a, b: string): bool =
  cmpPaths(normalizedPath(a), normalizedPath(b)) == 0

proc outcomeAt(entries: seq[JsonNode]; path: string): string =
  ## The outcome of the entry for `path` ("" when there is none).
  for e in entries:
    if samePath(e["path"].getStr, path):
      return e["outcome"].getStr
  ""

proc denyWrites(dir: string; deny: bool) =
  ## Makes `dir` unwritable for this user (`deny`), or writable again: mode
  ## 0555 / 0755 on POSIX; on Windows a deny ACE for Everyone's write and
  ## add-file rights, set and removed with icacls
  ## (https://learn.microsoft.com/windows-server/administration/windows-commands/icacls).
  when defined(windows):
    let args =
      if deny: @["icacls", dir, "/deny", "*S-1-1-0:(OI)(CI)(W)"]
      else: @["icacls", dir, "/remove:d", "*S-1-1-0"]
    let res = runShell(shellCommand(args), timeoutMs = 60_000)
    doAssert res.code == 0, res.output
  else:
    if deny:
      setFilePermissions(dir, {fpUserRead, fpUserExec, fpGroupRead,
        fpGroupExec, fpOthersRead, fpOthersExec})
    else:
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

# ---------------------------------------------------------------------------
# Driving the shells.
# ---------------------------------------------------------------------------

when defined(posix):
  proc shellEnv(w: World): seq[(string, string)] =
    for (k, v) in w.env:
      result.add((k, v))
    writeFile(w.dir / "inputrc", "set bell-style none\n")
    result.add(("CSM7_PATH", w.path))
    result.add(("TERM", "xterm-256color"))
    result.add(("LANG", (if existsEnv("LANG"): getEnv("LANG")
                         else: "C.UTF-8")))
    result.add(("INPUTRC", w.dir / "inputrc"))
    result.add(("PS1", "CSM7> "))
    # Shell history goes outside the home, which the test inspects.
    result.add(("HISTFILE", w.dir / "bash_history"))

  proc ready(s: var ShellSession; command: string): bool =
    ## Runs `command`, then an echo of a marker, and waits for the marker.
    s.settle(300, 10_000)
    s.send(command & "; echo CSM7_READ''Y\r")
    s.waitFor("CSM7_READY", 30_000) >= 0

  proc completedLine(s: var ShellSession; typed: string): string =
    ## Types `typed`, Tab, then turns the line into an echo of itself and
    ## runs it: what the shell completed.
    s.settle(300, 10_000)
    s.send(typed & "\t")
    # The shell runs `repro __complete` (the engine, a cold start) before it
    # redraws the line: wait for a long quiet spell.
    s.settle(1500, 15_000)
    s.send(EchoLine & "\r")
    s.lineAfter(LineMarker, 15_000).replace(LineMarker, "").strip()

  proc listed(s: var ShellSession; typed: string; tabs: int): string =
    ## Types `typed` and Tab `tabs` times, returns what the shell drew in
    ## answer (its candidate list), then abandons the line (Ctrl-C).
    s.settle(300, 10_000)
    let mark = s.output.len
    s.send(typed)
    s.settle(300, 5000)
    for i in 1 .. tabs:
      s.send("\t")
      s.settle(1500, 15_000)
    result = s.drawnSince(mark)
    s.send("\x03")
    s.settle(300, 5000)

  proc startShell(w: World; shell: string): ShellSession =
    let exe = (if shell == "powershell": shells()["pwsh"] else: shells()[shell])
    let args =
      case shell
      of "bash": @["--norc", "--noprofile", "-i"]
      of "zsh": @["-f", "-i"]
      else: @["--no-config", "-i"]
    result = spawnShell(shell, exe, args, w.shellEnv, w.dir / "work")
    result.settle(1500, 20_000)

  proc resetPath(shell: string): string =
    ## Startup files the options do not skip may assign PATH (NixOS's
    ## /etc/zshenv does): set it again.
    if shell == "fish": "set -gx PATH (string split : $CSM7_PATH)"
    else: "export PATH=\"$CSM7_PATH\""

  type ShellCheck = object
    label, got, expected: string

  proc completionCases(s: var ShellSession; shell: string): seq[ShellCheck] =
    ## The completion cases, in a shell that has loaded
    ## repro's completion.
    for (typed, expected) in [("repro wor", "repro workspace"),
        ("repro hooks ensure --shell-a",
         "repro hooks ensure --shell-autocomplete"),
        ("repro completion po", "repro completion powershell")]:
      result.add(ShellCheck(label: typed & " <Tab>",
        got: s.completedLine(typed), expected: expected))
    if shell == "fish":
      # fish's own completion machinery, asked for the whole list.
      s.settle(300, 10_000)
      let mark = s.output.len
      s.send("complete -C 'repro hooks ensure --shell-'; " &
        "complete -C 'repro completion '; echo CSM7_LIST''_END\r")
      discard s.waitFor("CSM7_LIST_END", 15_000)
      let drawn = s.drawnSince(mark)
      for want in ["--shell-autocomplete", "--shell-direnv", "bash", "zsh",
          "fish", "powershell"]:
        result.add(ShellCheck(label: "complete -C lists " & want,
          got: $(want in drawn), expected: "true"))
    else:
      let tabs = if shell == "bash": 2 else: 1
      let flags = s.listed("repro hooks ensure --shell-", tabs)
      for want in ["--shell-autocomplete", "--shell-direnv"]:
        result.add(ShellCheck(label: "repro hooks ensure --shell-<Tab> lists " &
          want, got: $(want in flags), expected: "true"))
      let names = s.listed("repro completion ", tabs)
      for want in ["bash", "zsh", "fish", "powershell"]:
        result.add(ShellCheck(label: "repro completion <Tab> lists " & want,
          got: $(want in names), expected: "true"))

  proc registrations(s: var ShellSession; shell: string): string =
    ## How many completion registrations for `repro` the shell holds, as
    ## the shell reports them.
    let command =
      case shell
      of "bash":
        # Builtins only: PATH holds the shells, not coreutils.
        "echo CSM7_REG''S:$(complete -p repro 2>/dev/null | " &
          "{ n=0; while read -r _; do n=$((n+1)); done; echo $n; })"
      of "zsh": "echo CSM7_REG''S:${#${(M)${(k)_comps}:#repro}}"
      else: "echo CSM7_REG''S:(complete -c repro | count)"
    s.settle(300, 10_000)
    s.send(command & "\r")
    s.lineAfter("CSM7_REGS:", 15_000).replace("CSM7_REGS:", "").strip()

  template checkAll(name: string; checks: seq[ShellCheck]) =
    for c in checks:
      checkpoint(name & ": " & c.label & " -> " & c.got)
      check c.got == c.expected

proc pwshCandidates(w: World; setup: string;
                    lines: openArray[string]): seq[seq[string]] =
  ## For each line, the `CompletionText`s `TabExpansion2` returns with the
  ## cursor at its end, after `setup` (which loads what was installed).
  var program = setup & "; foreach ($l in @("
  for i, l in lines:
    program.add((if i > 0: ", " else: "") & "'" & l.replace("'", "''") & "'")
  program.add(")) { 'CSM7_CASE'; (TabExpansion2 -inputScript $l " &
    "-cursorColumn $l.Length).CompletionMatches | ForEach-Object { " &
    "'CSM7_CAND:' + $_.CompletionText } }; 'CSM7_DONE'")
  var env = @(w.env)
  env.add(("POWERSHELL_TELEMETRY_OPTOUT", "1"))
  env.add(("POWERSHELL_UPDATECHECK", "Off"))
  env.add(("DOTNET_CLI_TELEMETRY_OPTOUT", "1"))
  let res = runShell(shellCommand(@[shells()["pwsh"], "-NoProfile",
    "-NonInteractive", "-Command", program], env), w.dir / "work",
    timeoutMs = 120_000)
  checkpoint("pwsh: " & res.output)
  doAssert "CSM7_DONE" in res.output, res.output
  for l in res.output.splitLines():
    let s = l.strip()
    if s == "CSM7_CASE":
      result.add(@[])
    elif s.startsWith("CSM7_CAND:") and result.len > 0:
      result[^1].add(s["CSM7_CAND:".len .. ^1])

const PwshLines = ["repro wor", "repro hooks ensure --shell-",
                   "repro completion "]

proc checkPwshCompletes(w: World; setup: string) =
  let lists = pwshCandidates(w, setup, PwshLines)
  check lists.len == 3
  if lists.len == 3:
    check "workspace" in lists[0]
    check "--shell-autocomplete" in lists[1]
    check "--shell-direnv" in lists[1]
    check ["bash", "zsh", "fish", "powershell"].toHashSet <=
      lists[2].toHashSet

suite "e2e_cs_m7_hooks_ensure_installs_completion":

  var before: seq[string]
  setup:
    before = hostState()
  teardown:
    check hostState() == before

  when not defined(windows):
    test "--profile installs each shell's file and block, once, and completes":
      let w = newWorld("profile")
      let loader = installLoader(w)
      let present = presentShells()
      check present.len > 0
      let first = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--profile", "--system-root=" & w.root, "--json"])
      checkpoint(first.output)
      check first.code == 0
      let got = outcomes(entriesOf(first.output))
      var expected = initHashSet[string]()
      if loader.len > 0:
        expected.incl(loader)
      for shell in present:
        let file = w.userFile(shell)
        check got.getOrDefault(file) == "installed"
        check readFile(file) == script(shell)
        expected.incl(file)
        let blockFile =
          if shell == "bash" and loader.len > 0: "" else: w.userBlockFile(shell)
        if blockFile.len > 0:
          check got.getOrDefault(blockFile) == "installed"
          check blockCount(blockFile, shell) == 1
          expected.incl(blockFile)
      # Nothing anywhere else: not in the home, not under the root.
      check filesUnder(w.home) + filesUnder(w.root) == expected
      check got.len == expected.len - (if loader.len > 0: 1 else: 0)

      # (3) A second run writes nothing.
      var stamps: seq[string] = @[]
      for p in expected:
        stamps.add(p & $getLastModificationTime(p).toUnixFloat &
          $hash(readFile(p)))
      sleep(1100)
      let second = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--system-root=" & w.root, "--json"])
      checkpoint(second.output)
      check second.code == 0
      for path, outcome in outcomes(entriesOf(second.output)):
        checkpoint(path)
        check outcome == "unchanged"
      var after: seq[string] = @[]
      for p in expected:
        after.add(p & $getLastModificationTime(p).toUnixFloat &
          $hash(readFile(p)))
      check after == stamps
      for shell in present:
        let blockFile = w.userBlockFile(shell)
        if blockFile.len > 0 and fileExists(blockFile):
          check blockCount(blockFile, shell) == 1

      # (2) Fresh shells complete from what was installed.
      when defined(posix):
        if "bash" in present:
          if loader.len == 0:
            skipLoud("bash-completion", "no bash-completion loader on this " &
              "machine (set REPRO_E2E_BASH_COMPLETION)")
          else:
            var s = w.startShell("bash")
            try:
              check s.ready(resetPath("bash") & "; source " & quoteShell(loader))
              checkAll("bash", s.completionCases("bash"))
              check s.registrations("bash") == "1"
            finally:
              checkpoint(s.transcript)
              s.stop()
        if "zsh" in present:
          var s = w.startShell("zsh")
          try:
            check s.ready(resetPath("zsh") & "; print -rl -- CSM7_FPATH $fpath")
            check s.ready("autoload -U compinit && compinit -u -D && source " &
              quoteShell(w.zdot / ".zshrc"))
            checkAll("zsh", s.completionCases("zsh"))
            check s.registrations("zsh") == "1"
          finally:
            checkpoint(s.transcript)
            s.stop()
        if "fish" in present:
          var s = w.startShell("fish")
          try:
            check s.ready(resetPath("fish") & "; set -g fish_complete_path " &
              "$XDG_CONFIG_HOME/fish/completions " &
              quoteShell(w.root / "etc/fish/completions") &
              " (for d in (string split : " &
              "$XDG_DATA_DIRS); echo $d/fish/vendor_completions.d; end) " &
              "$__fish_data_dir/completions")
            checkAll("fish", s.completionCases("fish"))
            check s.registrations("fish") == "1"
          finally:
            checkpoint(s.transcript)
            s.stop()
      if "powershell" in present:
        w.checkPwshCompletes(". " & "'" & w.userBlockFile("powershell") & "'")
      elif required("pwsh"):
        skipLoud("pwsh", "pwsh is not on PATH")
      for shell in ["bash", "zsh", "fish"]:
        if shell notin present:
          skipLoud(shell, shell & " is not on PATH")

    test "a shell with nothing installed does not complete (control)":
      let w = newWorld("control")
      when defined(posix):
        if "bash" in shells():
          var s = w.startShell("bash")
          try:
            let loader = bashLoader()
            let load = if loader.len > 0: "; source " & quoteShell(loader) else: ""
            check s.ready(resetPath("bash") & load)
            check s.completedLine("repro wor") == "repro wor"
          finally:
            checkpoint(s.transcript)
            s.stop()
        if "zsh" in shells():
          var s = w.startShell("zsh")
          try:
            check s.ready(resetPath("zsh") &
              "; autoload -U compinit && compinit -u -D")
            check s.completedLine("repro wor") == "repro wor"
          finally:
            checkpoint(s.transcript)
            s.stop()
        if "fish" in shells():
          var s = w.startShell("fish")
          try:
            check s.ready(resetPath("fish") & "; set -g fish_complete_path " &
              "$XDG_CONFIG_HOME/fish/completions $__fish_data_dir/completions")
            check s.completedLine("repro wor") == "repro wor"
          finally:
            checkpoint(s.transcript)
            s.stop()
      if "pwsh" in shells():
        let lists = pwshCandidates(w, "$null = 0", ["repro wor"])
        check lists.len == 1
        if lists.len == 1:
          check "workspace" notin lists[0]

    test "without bash-completion the ~/.bashrc block loads the file":
      if "bash" notin shells():
        skipLoud("bash", "bash is not on PATH")
      else:
        let w = newWorld("bashrc")
        let res = w.repro(["hooks", "ensure", "--shell-autocomplete",
          "--system-root=" & w.root, "--json"])
        checkpoint(res.output)
        check res.code == 0
        let got = outcomes(entriesOf(res.output))
        check got.getOrDefault(w.userFile("bash")) == "installed"
        check got.getOrDefault(w.home / ".bashrc") == "installed"
        check blockCount(w.home / ".bashrc", "bash") == 1
        when defined(posix):
          var s = w.startShell("bash")
          try:
            check s.ready(resetPath("bash") & "; source ~/.bashrc")
            check s.completedLine("repro wor") == "repro workspace"
          finally:
            checkpoint(s.transcript)
            s.stop()

    test "--system writes under the root only, completes, and registers once":
      let w = newWorld("system")
      let present = presentShells()
      let first = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--system", "--system-root=" & w.root, "--json"])
      checkpoint(first.output)
      check first.code == 0
      let entries = entriesOf(first.output)
      let got = outcomes(entries)
      # Nothing in the home (checked before any shell runs and writes its own
      # history or caches there).
      check filesUnder(w.home).len == 0
      for shell in present:
        let file = w.systemFile(shell)
        check got.getOrDefault(file) == "installed"
        check readFile(file) == script(shell)
      if "powershell" in present:
        # The all-users profile of the pwsh found, under the root: the
        # directory pwsh itself reports as $PSHOME.
        var profile = ""
        for e in entries:
          if e["shell"].getStr == "powershell" and
              e["target"].getStr == "profile-block":
            profile = e["path"].getStr
        check profile.startsWith(w.root)
        let psHome = runShell(shellCommand(@[shells()["pwsh"], "-NoProfile",
          "-NonInteractive", "-Command", "$PSHOME"])).output.strip()
        check profile == w.root / psHome.strip(trailing = false,
          chars = {'/'}) / "profile.ps1"
        check blockCount(profile, "powershell") == 1
        w.checkPwshCompletes(". '" & profile & "'")
      let second = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--system", "--system-root=" & w.root, "--json"])
      check second.code == 0
      for path, outcome in outcomes(entriesOf(second.output)):
        checkpoint(path)
        check outcome == "unchanged"
      when defined(posix):
        if "zsh" in present:
          var s = w.startShell("zsh")
          try:
            check s.ready(resetPath("zsh") & "; fpath=(" &
              quoteShell(w.root / "usr/local/share/zsh/site-functions") &
              " $fpath); autoload -U compinit && compinit -u -D")
            checkAll("zsh", s.completionCases("zsh"))
          finally:
            checkpoint(s.transcript)
            s.stop()
        if "fish" in present:
          var s = w.startShell("fish")
          try:
            check s.ready(resetPath("fish") & "; set -g fish_complete_path " &
              "$XDG_CONFIG_HOME/fish/completions " &
              quoteShell(w.root / "etc/fish/completions") &
              " (for d in (string split : " &
              "$XDG_DATA_DIRS); echo $d/fish/vendor_completions.d; end) " &
              "$__fish_data_dir/completions")
            checkAll("fish", s.completionCases("fish"))
          finally:
            checkpoint(s.transcript)
            s.stop()
        if "bash" in present:
          let loader = bashLoader()
          if loader.len == 0:
            skipLoud("bash-completion", "no bash-completion loader on this " &
              "machine (set REPRO_E2E_BASH_COMPLETION)")
          else:
            var s = w.startShell("bash")
            try:
              check s.ready(resetPath("bash") & "; source " & quoteShell(loader))
              check s.completedLine("repro wor") == "repro workspace"
            finally:
              checkpoint(s.transcript)
              s.stop()

      # (5) Registered once: --profile now finds the system-wide script and
      # writes nothing for this user (the shells above wrote their own state,
      # such as fish's history, so the home is compared with itself).
      let homeBefore = filesUnder(w.home)
      let profile = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--profile", "--system-root=" & w.root, "--json"])
      checkpoint(profile.output)
      check profile.code == 0
      let registered = entriesOf(profile.output)
      for shell in present:
        var outcome = ""
        for e in registered:
          if e["shell"].getStr == shell:
            outcome = e["outcome"].getStr
            check e["path"].getStr == w.systemFile(shell)
        check outcome == "already-registered-system"
      check filesUnder(w.home) == homeBefore

    test "a foreign file is refused, kept by uninstall, and the rest installed":
      let w = newWorld("foreign")
      discard installLoader(w)
      let present = presentShells()
      let foreign = w.userFile("bash")
      createDir(parentDir(foreign))
      let mine = "# my own repro completion\ncomplete -W 'a b' repro\n"
      writeFile(foreign, mine)
      let res = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--system-root=" & w.root, "--json"])
      checkpoint(res.output)
      let got = outcomes(entriesOf(res.output))
      if "bash" in present:
        check res.code == 1
        check got.getOrDefault(foreign) == "refused-foreign"
      check readFile(foreign) == mine
      for shell in present:
        if shell != "bash":
          check got.getOrDefault(w.userFile(shell)) == "installed"
      # (7) Uninstall removes what repro wrote and keeps the foreign file.
      let removed = w.repro(["hooks", "uninstall", "--shell-autocomplete",
        "--profile", "--system-root=" & w.root, "--json"])
      checkpoint(removed.output)
      check removed.code == 0
      check readFile(foreign) == mine
      check outcomes(entriesOf(removed.output)).getOrDefault(foreign) ==
        "kept-foreign"
      check filesUnder(w.home) == [foreign].toHashSet
      for shell in present:
        check blockCount(w.userBlockFile(shell), shell) == 0

  test "a bare ensure includes completion and the native integration":
    # The bare set is every hook type (the native shell
    # integration included): completion and the native block for each shell
    # found, once however often it runs, and a bare uninstall removes both.
    let w = newWorld("bare", withGit = true)
    let repo = w.dir / "work" / "repo"
    createDir(repo)
    let present = presentShells()
    check present.len > 0
    let saved = saveFiles(w.windowsProfiles())
    try:
      if "git" notin shells():
        skipLoud("git", "git is not on PATH")
      else:
        let init = runShell(shellCommand(@[shells()["git"], "init", "-q",
          repo], w.env))
        check init.code == 0
        for run in 1 .. 2:
          let bare = w.repro(["hooks", "ensure", "--system-root=" & w.root,
            repo])
          checkpoint("bare ensure #" & $run & ":\n" & bare.output)
          check bare.code == 0
          for shell in present:
            checkpoint(shell)
            check fileExists(w.userFile(shell))
            check nativeBlockCount(w.nativeRcFile(shell), shell) == 1
            check ("ensured native " & shell & " shell block at " &
              w.nativeRcFile(shell)) in bare.output
        let gone = w.repro(["hooks", "uninstall", "--system-root=" & w.root,
          repo])
        checkpoint("bare uninstall:\n" & gone.output)
        check gone.code == 0
        for shell in present:
          checkpoint(shell)
          check not fileExists(w.userFile(shell))
          check nativeBlockCount(w.nativeRcFile(shell), shell) == 0
    finally:
      restoreFiles(saved)
    let both = w.repro(["hooks", "ensure", "--shell-autocomplete",
      "--profile", "--system"])
    checkpoint(both.output)
    check both.code == 2
    check "--profile and --system" in both.output
    let vcsOnly = w.repro(["hooks", "ensure", "--vcs", "--system"])
    check vcsOnly.code == 2
    # The native integration has no system-wide file yet: named explicitly
    # with --system it is a usage error.
    let nativeSystem = w.repro(["hooks", "ensure", "--shell", "bash",
      "--system", "--system-root=" & w.root])
    checkpoint(nativeSystem.output)
    check nativeSystem.code == 2

  test "a bare ensure --system skips the native integration with a NOTE":
    var w = newWorld("bare-system", withGit = true)
    when defined(windows):
      # Scratch PowerShells only (and git), so `--system` writes no real
      # all-users profile whatever repro does with `$PSHOME`.
      w.path = fakePath(fakePowerShells(w),
        (if "git" in shells(): @[parentDir(shells()["git"])] else: @[]))
      require requireScratchPowerShells(w)
    let repo = w.dir / "work" / "repo"
    createDir(repo)
    let present = presentShells()
    check present.len > 0
    let saved = saveFiles(w.windowsProfiles())
    try:
      if "git" notin shells():
        skipLoud("git", "git is not on PATH")
      else:
        let init = runShell(shellCommand(@[shells()["git"], "init", "-q",
          repo], w.env))
        check init.code == 0
        let bare = w.repro(["hooks", "ensure", "--system",
          "--system-root=" & w.root, repo])
        checkpoint(bare.output)
        check bare.code == 0
        check "NOTE the native shell integration has no system-wide file" in
          bare.output
        for shell in present:
          checkpoint(shell)
          check fileExists(w.systemFile(shell))
        for shell in present:
          checkpoint(shell)
          check nativeBlockCount(w.nativeRcFile(shell), shell) == 0
          check "ensured native" notin bare.output
    finally:
      restoreFiles(saved)

  when defined(windows):
    test "Windows: --profile writes the profiles under the reported Documents":
      let w = newWorld("windows-profile")
      # Documents as PowerShell reports it in the case's environment: where
      # repro must write, and where the PowerShell started below reads.
      let docs = windowsDocuments(w.env)
      check docs.len > 0
      let saved = saveFiles(w.windowsProfiles())
      try:
        let first = w.repro(["hooks", "ensure", "--shell-autocomplete",
          "--profile", "--json"])
        checkpoint(first.output)
        check first.code == 0
        let got = outcomes(entriesOf(first.output))
        let scriptFile = w.userFile("powershell")
        check got.getOrDefault(scriptFile) == "installed"
        check readFile(scriptFile) == script("powershell")
        var blocks: seq[string] = @[]
        if "pwsh" in shells():
          blocks.add(docs / "PowerShell" / "Profile.ps1")
        if "powershell" in shells():
          blocks.add(docs / "WindowsPowerShell" / "Profile.ps1")
        check blocks.len > 0
        for b in blocks:
          checkpoint(b)
          check got.getOrDefault(b) == "installed"
          check blockCount(b, "powershell") == 1
        # Nothing else under %USERPROFILE%: repro writes the profiles where
        # the reported Documents folder is (inside the scratch home when it
        # is expanded from %USERPROFILE%), and nothing beside them.
        for f in filesUnder(w.home):
          checkpoint(f)
          check f in blocks
        let second = w.repro(["hooks", "ensure", "--shell-autocomplete",
          "--profile", "--json"])
        checkpoint(second.output)
        check second.code == 0
        for path, outcome in outcomes(entriesOf(second.output)):
          checkpoint(path)
          check outcome == "unchanged"
        if "pwsh" in shells():
          w.checkPwshCompletes(". '" & blocks[0] & "'")
        let removed = w.repro(["hooks", "uninstall", "--shell-autocomplete",
          "--profile", "--json"])
        checkpoint(removed.output)
        check removed.code == 0
        check not fileExists(scriptFile)
        for b in blocks:
          check blockCount(b, "powershell") == 0
      finally:
        restoreFiles(saved)

  test "--system: a writable $PSHOME gets the block once, uninstall removes it":
    # Scratch PowerShells only (`fakePowerShells`), so the all-users profile
    # repro writes can only be under the root or in scratch.
    var w = newWorld("pshw")
    let fakes = fakePowerShells(w)
    w.path = fakePath(fakes)
    require requireScratchPowerShells(w)
    let scriptFile = w.systemFile("powershell")
    for run in 1 .. 2:
      let res = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--system", "--system-root=" & w.root, "--json"])
      checkpoint("ensure #" & $run & ":\n" & res.output)
      check res.code == 0
      let entries = entriesOf(res.output)
      let want = if run == 1: "installed" else: "unchanged"
      check outcomeAt(entries, scriptFile) == want
      check readFile(scriptFile) == script("powershell")
      for f in fakes:
        checkpoint(f.exe)
        check outcomeAt(entries, w.allUsersProfile(f)) == want
        check blockCount(w.allUsersProfile(f), "powershell") == 1
        # The block loads the script --system installed.
        check fileExists(w.allUsersProfile(f)) and
          scriptFile.extractFilename in readFile(w.allUsersProfile(f))
      # One file and one block per PowerShell: nothing else reported.
      check entries.len == 1 + fakes.len
      check writtenIntoFakes(fakes).len == 0
    # Nothing per user.
    check filesUnder(w.home).len == 0
    let gone = w.repro(["hooks", "uninstall", "--shell-autocomplete",
      "--system", "--system-root=" & w.root, "--json"])
    checkpoint("uninstall:\n" & gone.output)
    check gone.code == 0
    let removed = entriesOf(gone.output)
    check outcomeAt(removed, scriptFile) == "removed"
    check not fileExists(scriptFile)
    for f in fakes:
      check outcomeAt(removed, w.allUsersProfile(f)) == "removed"
      check blockCount(w.allUsersProfile(f), "powershell") == 0
    check writtenIntoFakes(fakes).len == 0

  test "--system: an unwritable $PSHOME is refused, the per-user block kept":
    var w = newWorld("pshro")
    let fakes = fakePowerShells(w)
    w.path = fakePath(fakes)
    require requireScratchPowerShells(w)
    let saved = saveFiles(w.windowsProfiles())
    var denied: seq[string] = @[]
    try:
      # The per-user registration the refusal must leave alone.
      let user = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--profile", "--system-root=" & w.root, "--json"])
      checkpoint("--profile:\n" & user.output)
      check user.code == 0
      var userFiles: seq[string] = @[]
      for e in entriesOf(user.output):
        check e["outcome"].getStr == "installed"
        userFiles.add(e["path"].getStr)
      check userFiles.len == 1 + fakes.len
      var userBefore: seq[string] = @[]
      for f in userFiles:
        userBefore.add(readFile(f))
      for f in fakes:
        let home = underRoot(w, f.home)
        createDir(home)
        denyWrites(home, true)
        denied.add(home)
      let res = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--system", "--system-root=" & w.root, "--json"])
      checkpoint("--system:\n" & res.output)
      check res.code == 1
      let entries = entriesOf(res.output)
      check entries.len == fakes.len
      for f in fakes:
        checkpoint(f.exe)
        check outcomeAt(entries, w.allUsersProfile(f)) == "refused-unwritable"
        check ("REFUSED powershell completion block at " &
          w.allUsersProfile(f)) in res.output
        check not fileExists(w.allUsersProfile(f))
      check "is not writable" in res.output
      # Nothing under the root (no script without a block to load it), and
      # the per-user files byte for byte as they were.
      check filesUnder(w.root).len == 0
      for i, f in userFiles:
        checkpoint(f)
        check readFile(f) == userBefore[i]
      check writtenIntoFakes(fakes).len == 0
    finally:
      for home in denied:
        denyWrites(home, false)
      restoreFiles(saved)

  when not defined(windows):
    test "--system-root keeps every write inside the root and is in no help":
      # A link inside the root that leads out of it must not carry a write
      # onto the machine: `--system-root` re-roots paths, nothing else.
      let w = newWorld("escape")
      let outside = w.dir / "outside"
      createDir(outside)
      createDir(w.root / "usr")
      createSymlink(outside, w.root / "usr" / "local")
      # Fish's Linux `--system` directory is under `etc/fish`, not `usr/local`,
      # so it gets a link out of the root of its own.
      let outsideEtc = w.dir / "outside-etc"
      createDir(outsideEtc)
      createDir(w.root / "etc")
      createSymlink(outsideEtc, w.root / "etc" / "fish")
      let present = presentShells()
      check present.len > 0
      let res = w.repro(["hooks", "ensure", "--shell-autocomplete",
        "--system", "--system-root=" & w.root, "--json"])
      checkpoint(res.output)
      check res.code == 1
      let got = outcomes(entriesOf(res.output))
      for shell in present:
        check got.getOrDefault(w.systemFile(shell)) == "failed"
      var leaked: seq[string] = @[]
      for dir in [outside, outsideEtc]:
        for p in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
            pcLinkToDir}):
          leaked.add(p)
      check leaked.len == 0
      # Internal: no help shows it.
      for args in [@["hooks", "ensure", "--help"],
          @["hooks", "reinstall", "--help"], @["hooks", "uninstall", "--help"]]:
        let help = w.repro(args)
        checkpoint(help.output)
        check help.code == 0
        check "--system-root" notin help.output
        check "--system" in help.output
