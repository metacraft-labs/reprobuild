## test_cs_m8e_macos_shell_placements (the Linux part): the macOS rules of
## `repro hooks ensure --shell-autocomplete`, driven on any host through the
## request's `macos` field, with a real bash reading the files it wrote.
##
## * **Bash `--profile` writes two files.** Terminal.app starts login
##   shells, which read `~/.bash_profile` (or, when that is absent,
##   `~/.bash_login` or `~/.profile`), never `~/.bashrc`; an interactive
##   shell that is not a login shell reads `~/.bashrc` only (the Bash manual,
##   "Bash Startup Files",
##   https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html).
##   So the block goes in both, and is guarded so that it runs once when
##   one file sources the other. The cases start the real bash as a login
##   shell (`bash -l`) and as an interactive non-login shell (`bash -i`),
##   each with `-x`, and count how often the block sourced the script (the
##   traced `. <script>` lines), then complete `repro wor` with the function
##   the script registered, which runs the real `repro __complete`.
##   The negative control rewrites both blocks without the guard: the login
##   shell then sources the script twice, which the count rejects. The
##   guard's marker must never reach the environment, even under `set -a`
##   (a child shell inherits no `complete` registration, and an inherited
##   marker would stop it loading the script): each shell reports how many
##   markers its environment holds.
## * **Fish `--system` goes to `/etc/fish/completions`**, as on Linux, not
##   to `/usr/local/share/fish/vendor_completions.d`, which fish on macOS
##   does not search unless `XDG_DATA_DIRS` names `/usr/local/share`.
##
## Every path is under a per-case scratch directory: `HOME` and the XDG
## directories, and the system root (`systemRoot`, the internal
## `--system-root`), which also hides the host's bash-completion so the
## blocks are written. The shells are started with that `HOME`; a login
## bash still reads the host's `/etc/profile` (bash cannot be told not to
## without also skipping `~/.bash_profile`), which this test only reads.
## The script written is the one the built `repro completion <shell>`
## prints. Nothing is mocked. What only a Mac can confirm (Terminal.app's
## own login shell, macOS's bash 3.2, a stock fish searching
## `/etc/fish/completions`) is the macOS run of the same test name.

import std/[os, osproc, streams, strtabs, strutils, unittest]

import repro_test_support
import clispec/completion
import repro_cli_support/completion_hooks
from repro_core/process_streams import drainStream

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Scratch = object
  base, home, root, bin: string

proc completingBash(): string =
  ## The first bash on PATH that has the `complete` builtin: nixpkgs' plain
  ## `bash` is built without readline, and so without it.
  for dir in getEnv("PATH").split(PathSep):
    let exe = dir / "bash"
    if dir.len == 0 or not fileExists(exe):
      continue
    let (_, code) = execCmdEx(quoteShellCommand([exe, "-c", "type complete"]))
    if code == 0:
      return exe
  ""

proc newScratch(name: string): Scratch =
  result.base = getTempDir() / ("cs_m8e_" & name & testCaseScratchSlug())
  if dirExists(result.base):
    removeDir(result.base)
  result.home = result.base / "home"
  result.root = result.base / "root"
  result.bin = result.base / "bin"
  for d in [result.home, result.root, result.bin]:
    createDir(d)
  # The shells repro looks for: links to the real ones, nothing else.
  for (sh, exe) in [("bash", completingBash()), ("fish", findExe("fish"))]:
    if exe.len > 0:
      createSymlink(exe, result.bin / sh)

proc request(s: Scratch; scope = csUser; macos = true):
    CompletionHookRequest =
  let home = s.home
  let repro = reproBinary()
  CompletionHookRequest(
    scope: scope, systemRoot: s.root, program: "repro",
    env: CliInstallEnv(home: home, xdgDataHome: home / ".local/share",
      xdgConfigHome: home / ".config"),
    pathEnv: s.bin, user: "nobody", macos: macos,
    script: proc (shell: CliShell): string =
      let (output, code) = execCmdEx(quoteShellCommand(
        [repro, "completion", $shell]))
      doAssert code == 0, "repro completion " & $shell & ": " & output
      output)

proc scriptPath(s: Scratch): string =
  s.home / ".local/share/bash-completion/completions/repro"

proc blockCount(path: string): int =
  ## How many repro completion blocks `path` holds.
  if not fileExists(path):
    return 0
  readFile(path).count(completionBlockId(cshBash))

type ShellRun = object
  sourced: int     ## how often the script was sourced (traced `. <script>`)
  completed: string ## what `repro wor` completed to
  exported: string  ## how many run-once markers are in the environment
  output: string

proc runBash(s: Scratch; mode: string): ShellRun =
  ## Start the real bash as `bash <mode> -x -c ...` with the scratch HOME,
  ## then complete `repro wor` with the function `complete -p repro` names.
  let probe = """
echo "CSM8E_EXPORTED:$(env | grep -c '^__clispec_completion_')"
fn=$(complete -p repro 2>/dev/null | sed -n 's/.*-F \([^ ]*\) .*/\1/p')
if [ -z "$fn" ]; then echo "CSM8E_NOCOMPLETE"; exit 0; fi
set +x
COMP_LINE="repro wor"; COMP_POINT=${#COMP_LINE}
COMP_WORDS=(repro wor); COMP_CWORD=1
"$fn" repro wor repro
echo "CSM8E_REPLY:${COMPREPLY[*]}"
"""
  let env = newStringTable(modeCaseSensitive)
  env["HOME"] = s.home
  env["PATH"] = reproBinary().parentDir & PathSep & s.bin & PathSep &
    getEnv("PATH")
  env["TERM"] = "dumb"
  env["PS4"] = "+CSM8E "
  let p = startProcess(s.bin / "bash", workingDir = s.home,
    args = [mode, "-x", "-c", probe], env = env,
    options = {poStdErrToStdOut})
  let output = drainStream(p.outputStream)
  discard p.waitForExit()
  p.close()
  result.output = output
  let traced = ". " & s.scriptPath
  for line in output.splitLines():
    let l = line.strip(trailing = false, chars = {'+'})
    if l.startsWith("CSM8E " & traced):
      inc result.sourced
    if line.startsWith("CSM8E_EXPORTED:"):
      result.exported = line["CSM8E_EXPORTED:".len .. ^1]
    if line.startsWith("CSM8E_REPLY:"):
      result.completed = line["CSM8E_REPLY:".len .. ^1]

proc outcomes(entries: seq[CompletionHookEntry]): seq[string] =
  for e in entries:
    result.add($e.shell & " " & $e.target & " " & e.path & " " & $e.outcome)

proc bashOnly(entries: seq[CompletionHookEntry]): seq[CompletionHookEntry] =
  ## The Bash entries (fish is on the scratch PATH too, for the last case).
  for e in entries:
    if e.shell == cshBash:
      result.add e

suite "test_cs_m8e_macos_shell_placements":

  test "bash --profile on macOS: both files, each shell runs the block once":
    let s = newScratch("bash")
    if not fileExists(s.bin / "bash"):
      echo "SKIP-LOUD: no bash with the complete builtin on PATH; this case did NOT run"
      check getEnv("REPRO_E2E_REQUIRE_SHELLS").len == 0
    else:
      # A common macOS setup: the login file sources ~/.bashrc.
      writeFile(s.home / ".bash_profile",
        "[ -r ~/.bashrc ] && . ~/.bashrc\n")
      writeFile(s.home / ".bashrc", "# the user's own\n")
      let first = ensureCompletionHooks(request(s))
      checkpoint(outcomes(first).join("\n"))
      check completionExitCode(first) == 0
      check outcomes(bashOnly(first)) == @[
        "bash file " & s.scriptPath & " installed",
        "bash profile-block " & s.home / ".bashrc" & " installed",
        "bash profile-block " & s.home / ".bash_profile" & " installed"]
      check blockCount(s.home / ".bashrc") == 2      # begin and end marker
      check blockCount(s.home / ".bash_profile") == 2
      # (a) a Terminal.app-style login shell: ~/.bash_profile, which
      # sources ~/.bashrc; the script is sourced once and completes.
      let login = runBash(s, "-l")
      checkpoint(login.output)
      check login.sourced == 1
      check login.completed == "workspace"
      # (b) an interactive non-login shell: ~/.bashrc only.
      let inter = runBash(s, "-i")
      checkpoint(inter.output)
      check inter.sourced == 1
      check inter.completed == "workspace"
      # (c) a second ensure changes nothing and adds no second block.
      let second = ensureCompletionHooks(request(s))
      checkpoint(outcomes(second).join("\n"))
      for e in second:
        check e.outcome == coUnchanged
      check bashOnly(second).len == 3
      check blockCount(s.home / ".bashrc") == 2
      check blockCount(s.home / ".bash_profile") == 2
      check runBash(s, "-l").sourced == 1
      check login.exported == "0"
      # (c2) a login file that runs `set -a` (every assignment exported)
      # still leaves the marker unexported: a shell started from this one
      # inherits no `complete` registration, so it must load the script
      # again, and an inherited marker would stop it.
      let plainProfile = readFile(s.home / ".bash_profile")
      writeFile(s.home / ".bash_profile", "set -a\n" & plainProfile)
      let allexport = runBash(s, "-l")
      checkpoint(allexport.output)
      check allexport.sourced == 1
      check allexport.exported == "0"
      check allexport.completed == "workspace"
      writeFile(s.home / ".bash_profile", plainProfile)
      # (d) the negative control: the same blocks without the guard. The
      # login shell meets both and sources the script twice, which (a)'s
      # count rejects.
      for rc in [".bashrc", ".bash_profile"]:
        let path = s.home / rc
        let guarded = cliProfileBlockBody(cshBash, "repro", s.scriptPath,
          runOnce = true)
        let text = readFile(path)
        check guarded.strip in text
        writeFile(path, text.replace(guarded.strip,
          cliProfileBlockBody(cshBash, "repro", s.scriptPath).strip))
      let unguarded = runBash(s, "-l")
      checkpoint(unguarded.output)
      check unguarded.sourced == 2
      # Uninstall takes both blocks away and leaves the user's lines.
      let removed = uninstallCompletionHooks(request(s))
      checkpoint(outcomes(removed).join("\n"))
      check completionExitCode(removed) == 0
      check blockCount(s.home / ".bashrc") == 0
      check blockCount(s.home / ".bash_profile") == 0
      check readFile(s.home / ".bash_profile") ==
        "[ -r ~/.bashrc ] && . ~/.bashrc\n"
      check runBash(s, "-l").completed == ""
      removeDir(s.base)

  test "bash --profile on macOS: no ~/.bash_profile is created over ~/.profile":
    let s = newScratch("profile")
    if not fileExists(s.bin / "bash"):
      echo "SKIP-LOUD: no bash with the complete builtin on PATH; this case did NOT run"
      check getEnv("REPRO_E2E_REQUIRE_SHELLS").len == 0
    else:
      # A login bash reads ~/.profile when there is no ~/.bash_profile or
      # ~/.bash_login; creating ~/.bash_profile would make it stop.
      writeFile(s.home / ".profile", "export CSM8E_PROFILE_READ=1\n")
      let entries = ensureCompletionHooks(request(s))
      checkpoint(outcomes(entries).join("\n"))
      check completionExitCode(entries) == 0
      check not fileExists(s.home / ".bash_profile")
      check blockCount(s.home / ".profile") == 2
      check blockCount(s.home / ".bashrc") == 2
      let login = runBash(s, "-l")
      checkpoint(login.output)
      check login.sourced == 1
      check login.completed == "workspace"
      # Idempotent here too, and uninstall finds the block in ~/.profile.
      for e in ensureCompletionHooks(request(s)):
        check e.outcome == coUnchanged
      check not fileExists(s.home / ".bash_profile")
      discard uninstallCompletionHooks(request(s))
      check blockCount(s.home / ".profile") == 0
      check readFile(s.home / ".profile") == "export CSM8E_PROFILE_READ=1\n"
      removeDir(s.base)

  test "bash --profile elsewhere: ~/.bashrc only, the block unchanged":
    let s = newScratch("linux")
    if not fileExists(s.bin / "bash"):
      echo "SKIP-LOUD: no bash with the complete builtin on PATH; this case did NOT run"
      check getEnv("REPRO_E2E_REQUIRE_SHELLS").len == 0
    else:
      let entries = ensureCompletionHooks(request(s, macos = false))
      checkpoint(outcomes(entries).join("\n"))
      check outcomes(bashOnly(entries)) == @[
        "bash file " & s.scriptPath & " installed",
        "bash profile-block " & s.home / ".bashrc" & " installed"]
      check not fileExists(s.home / ".bash_profile")
      check cliProfileBlockBody(cshBash, "repro", s.scriptPath).strip in
        readFile(s.home / ".bashrc")
      check "__clispec_completion_" notin readFile(s.home / ".bashrc")
      removeDir(s.base)

  test "fish --system on macOS: /etc/fish/completions, as on Linux":
    let s = newScratch("fish")
    if not fileExists(s.bin / "fish"):
      echo "SKIP-LOUD: fish is not on PATH; this case did NOT run"
      check getEnv("REPRO_E2E_REQUIRE_SHELLS").len == 0
    else:
      let entries = ensureCompletionHooks(request(s, scope = csSystem))
      checkpoint(outcomes(entries).join("\n"))
      check completionExitCode(entries) == 0
      let wanted = s.root / "etc/fish/completions/repro.fish"
      let old = s.root / "usr/local/share/fish/vendor_completions.d/repro.fish"
      check fileExists(wanted)
      check not fileExists(old)
      check "fish file " & wanted & " installed" in outcomes(entries)
      # Bash and Zsh stay under /usr/local/share.
      check fileExists(s.root /
        "usr/local/share/bash-completion/completions/repro")
      # Per user, the system file counts as the registration.
      let user = ensureCompletionHooks(request(s))
      checkpoint(outcomes(user).join("\n"))
      check "fish file " & wanted & " already-registered-system" in
        outcomes(user)
      discard uninstallCompletionHooks(request(s, scope = csSystem))
      check not fileExists(wanted)
      removeDir(s.base)
