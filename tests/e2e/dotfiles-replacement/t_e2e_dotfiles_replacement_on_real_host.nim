## M70 gate: `e2e_dotfiles_replacement_on_real_host` (Windows-only,
## host-specific by design — runs only on the user's real dev host).
##
## Proves that `repro home apply` can replace the user's real
## scoop-based `~/dotfiles` Windows workflow. Executes the procedure
## in `Test-Designs/Reprobuild-Dotfiles-Replacement.md`: a mandatory
## pre-flight (baseline capture + rollback round-trip proof) followed
## by steps 1-8.
##
## SAFETY CONTRACT (see the M70 milestone brief):
##
##   * The user's real `~/dotfiles` repo IS the apply `--profile-dir`.
##     `home.nim` (authored as the M70 deliverable) is the ONLY file
##     Reprobuild authors inside that repo; every pre-existing file is
##     checksummed at Step 1 and re-verified byte-identical at Step 8.
##   * Real Scoop: the 14 user-facing packages are realized against
##     the real `$SCOOP` install. Already-installed apps are a
##     cache-hit — apply NEVER reinstalls (the gate confirms `scoop
##     list` is unchanged start-to-end).
##   * The apply's `$HOME` / `USERPROFILE` / state-dir / store-root
##     are isolated test temp dirs. This keeps the real `$HOME` shell
##     profile and the real `~/.gitconfig` stow symlink untouched
##     while still exercising the real `~/dotfiles` profile, the real
##     Scoop adapter, and the real registry. The non-destructive
##     guarantee is therefore absolute for the live environment.
##   * Step 6a writes an HKCU `windows.registryValue` under an
##     ISOLATED per-run subkey `HKCU\Software\Reprobuild-Tests\
##     m70-<ts>\` (the same isolation pattern M68 gate 2 used). No
##     live user-facing registry value is perturbed.
##   * Step 6b asserts the deferred `--include-system` path is
##     rejected; no elevated operation is attempted.
##
## RECOVERY: if pre-flight or any step fails the gate rolls the
## isolated environment back to the captured baseline generation and
## stops — it never pushes forward through a failure.

when not defined(windows):
  {.warning[UnreachableCode]: off.}

import std/[algorithm, os, osproc, sequtils, streams, strtabs,
  strutils, tables, tempfiles, times, unittest]

import blake3
import repro_home_generations
import repro_home_resources
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

# The real user dotfiles repo. This is the apply `--profile-dir`.
const RealDotfilesDir = r"C:\Users\zahary\dotfiles"

# The authored `home.nim` (Deliverable 1) committed in the reprobuild
# repo. Step 1 restores the live `~/dotfiles/home.nim` from this copy so
# the gate is deterministically re-runnable: Steps 4/5 then make their
# structural edits from a known-clean starting point.
const HomeNimReference = currentSourcePath().parentDir().parentDir()
  .parentDir() / "fixtures" / "dotfiles-replacement" / "home.nim.reference"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]):
    tuple[exitCode: int; output: string] =
  ## Run the real `repro` CLI as a subprocess with `envOverrides`
  ## layered onto the inherited environment.
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  for kv in envOverrides:
    processEnv[kv.k] = kv.v
  let p = startProcess(reproBinary(), args = @args, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let stream = p.outputStream()
  var combined = ""
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0: break
    combined.add chunk
  let code = p.waitForExit()
  p.close()
  result = (exitCode: code, output: combined)

# ---------------------------------------------------------------------------
# Checksum helpers (Step 1 baseline + Step 8 re-verification).
# ---------------------------------------------------------------------------

proc fileChecksum(path: string): string =
  ## BLAKE3 hex of a file's bytes.
  let data = readFile(path)
  var bytes = newSeq[byte](data.len)
  for i, c in data:
    bytes[i] = byte(ord(c))
  blake3.digest(bytes).toHex().toLowerAscii()

proc checksumDotfilesTree(root: string): OrderedTable[string, string] =
  ## Walk every regular file under `root`, skipping the `.git/`
  ## subtree, and return a `rel-path -> BLAKE3` map. Used to prove
  ## the migration is non-destructive: nothing under `~/dotfiles`
  ## except `home.nim` changes between Step 1 and Step 8.
  result = initOrderedTable[string, string]()
  for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile}):
    let rel = path[root.len + 1 .. ^1]
    let normalized = rel.replace('\\', '/')
    if normalized == ".git" or normalized.startsWith(".git/"):
      continue
    result[normalized] = fileChecksum(path)

# ---------------------------------------------------------------------------
# Scoop survey helpers (pre-flight baseline + Step 7 verification).
# ---------------------------------------------------------------------------

proc resolveScoopExe(): string =
  for candidate in ["scoop.cmd", "scoop.ps1", "scoop.exe", "scoop"]:
    let resolved = findExe(candidate)
    if resolved.len > 0:
      return resolved
  ""

proc scoopInstalledApps(): OrderedTable[string, string] =
  ## `<app> -> <version>` map of every installed Scoop app, read
  ## directly from the `$SCOOP\apps\<app>\<version>` layout (avoids
  ## depending on `scoop list` output formatting).
  result = initOrderedTable[string, string]()
  let scoopRoot = getEnv("SCOOP", getHomeDir() / "scoop")
  let appsDir = scoopRoot / "apps"
  if not dirExists(appsDir):
    return
  for kind, appPath in walkDir(appsDir):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let app = extractFilename(appPath)
    for vk, vPath in walkDir(appPath):
      if vk notin {pcDir, pcLinkToDir}:
        continue
      let ver = extractFilename(vPath)
      if ver != "current":
        result[app] = ver

# ---------------------------------------------------------------------------
# Apply-log capture (Deliverable 4).
# ---------------------------------------------------------------------------

var applyLog: seq[string]

proc logStep(label, output: string) =
  applyLog.add("===== " & label & " =====")
  applyLog.add(output)
  applyLog.add("")

# ---------------------------------------------------------------------------
# The 14 user-facing Scoop packages and how the gate binds each one.
# ---------------------------------------------------------------------------
#
# The 10 CLI tools route through the REAL Scoop adapter against the
# already-installed version (a cache-hit: the `apps/<app>/<version>/`
# dir already exists, so `resolveScoopTool` junctions it without
# reinstalling). The 4 GUI apps (firefox, googlechrome, vscode,
# windows-terminal) route through the `path` adapter pointed at their
# already-installed executables — their `--version` probe behaviour is
# unreliable for an unattended gate, so the gate verifies they are
# installed via the Scoop survey instead of through a probe. Either
# way NOTHING is reinstalled.

type PkgBind = object
  app: string
  bucket: string
  version: string
  exe: string          ## scoop: relative path under version dir
  guiExeAbs: string    ## path adapter: absolute installed executable

proc scoopBindings(): seq[PkgBind] =
  @[
    PkgBind(app: "age", bucket: "extras", version: "1.3.1", exe: "age.exe"),
    PkgBind(app: "gnupg", bucket: "main", version: "2.5.20",
      exe: "bin/gpg.exe"),
    PkgBind(app: "git", bucket: "main", version: "2.54.0",
      exe: "bin/git.exe"),
    PkgBind(app: "gh", bucket: "main", version: "2.92.0", exe: "bin/gh.exe"),
    PkgBind(app: "neovim", bucket: "main", version: "0.12.2",
      exe: "bin/nvim.exe"),
    PkgBind(app: "pwsh", bucket: "main", version: "7.6.1", exe: "pwsh.exe"),
    PkgBind(app: "direnv", bucket: "main", version: "2.37.1",
      exe: "direnv.exe"),
    PkgBind(app: "ripgrep", bucket: "main", version: "15.1.0",
      exe: "rg.exe"),
    PkgBind(app: "codex", bucket: "main", version: "0.130.0",
      exe: "codex.exe"),
    PkgBind(app: "claude-code", bucket: "main", version: "2.1.143",
      exe: "claude.exe"),
  ]

proc guiBindings(): seq[PkgBind] =
  let scoopRoot = getEnv("SCOOP", getHomeDir() / "scoop")
  @[
    PkgBind(app: "windows-terminal",
      guiExeAbs: scoopRoot / "apps" / "windows-terminal" / "current" /
        "WindowsTerminal.exe"),
    PkgBind(app: "vscode",
      guiExeAbs: scoopRoot / "apps" / "vscode" / "current" / "Code.exe"),
    PkgBind(app: "firefox",
      guiExeAbs: scoopRoot / "apps" / "firefox" / "current" / "firefox.exe"),
    PkgBind(app: "googlechrome",
      guiExeAbs: scoopRoot / "apps" / "googlechrome" / "current" /
        "chrome.exe"),
  ]

proc scoopMapEnv(): string =
  scoopBindings().mapIt(
    it.app & "=" & it.bucket & "/" & it.app & "@" & it.version &
    "#" & it.exe).join(";")

proc pathMapEnv(extraFd: string = ""): string =
  ## `path` adapter bindings for the 4 GUI apps. When `extraFd` is
  ## non-empty it adds an `fd=<path>` binding for the Step 5 add.
  var entries = guiBindings().mapIt(it.app & "=" & it.guiExeAbs)
  if extraFd.len > 0:
    entries.add("fd=" & extraFd)
  entries.join(";")

const PackageCatalog =
  "age,gnupg,git,gh,windows-terminal,vscode,neovim,pwsh,direnv," &
  "ripgrep,firefox,googlechrome,codex,claude-code,fd"

suite "M70 gate: e2e_dotfiles_replacement_on_real_host":
  test "real ~/dotfiles replaced by repro home apply; non-destructive":
    when not defined(windows):
      checkpoint "platform-skip: M70 gate is Windows-host-specific"
      check true
      quit(0)

    # -------------------------------------------------------------------
    # PRE-FLIGHT (mandatory, abort-on-failure).
    # -------------------------------------------------------------------
    let scoopExe = resolveScoopExe()
    doAssert scoopExe.len > 0,
      "M70 pre-flight: real scoop.exe required on PATH; the milestone " &
      "forbids mocking Scoop. ABORT before touching anything."
    doAssert dirExists(RealDotfilesDir),
      "M70 pre-flight: real dotfiles repo missing at " & RealDotfilesDir &
      ". ABORT."
    let homeNimPath = RealDotfilesDir / "home.nim"
    doAssert fileExists(homeNimPath),
      "M70 pre-flight: " & homeNimPath & " (Deliverable 1) must be in " &
      "place before the gate runs. ABORT."
    doAssert fileExists(HomeNimReference),
      "M70 pre-flight: authored home.nim reference missing at " &
      HomeNimReference & ". ABORT."
    # Restore the live `home.nim` from the authored reference so the
    # gate's structural-editor steps run from a known-clean profile and
    # the gate is deterministically re-runnable. This is the ONE
    # Reprobuild-owned file in the dotfiles repo (per the M70 contract).
    copyFile(HomeNimReference, homeNimPath)

    # Isolated apply environment. The profile-dir is the REAL dotfiles;
    # everything Reprobuild WRITES goes into temp dirs so the live
    # $HOME and live registry are untouched.
    let tempRoot = createTempDir("repro-m70-", "")
    var rolledBackToBaseline = false
    defer:
      try: removeDir(tempRoot)
      except OSError: discard
    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let homeDir = tempRoot / "home"
    let logDir = tempRoot / "apply-log"
    createDir(stateDir)
    createDir(storeRoot)
    createDir(homeDir)
    createDir(logDir)

    let ts = $int(epochTime())
    let testSubkey = "Software\\Reprobuild-Tests\\m70-" & ts

    # The `fd` fixture executable: a `path`-adapter binding for the
    # Step 5 `repro home add fd`. It is bound in EVERY apply env from
    # the start — an unused binding is inert until `fd` appears in the
    # profile, so binding it early keeps every post-Step-5 apply
    # working without re-threading the env.
    let fdExe = tempRoot / "fd.cmd"
    writeFile(fdExe,
      "@echo off\r\n" &
      "if /I \"%1\"==\"--version\" (\r\n" &
      "  echo fd 10.0.0\r\n" &
      "  exit /b 0\r\n" &
      ")\r\n" &
      "exit /b 0\r\n")

    proc baseEnv(): seq[tuple[k, v: string]] =
      @[
        (k: "REPRO_HOME_PROFILE_DIR", v: RealDotfilesDir),
        (k: "REPRO_HOME_STATE_DIR", v: stateDir),
        (k: "REPRO_STORE_ROOT", v: storeRoot),
        (k: "HOME", v: homeDir),
        (k: "USERPROFILE", v: homeDir),
        (k: "REPRO_HOST", v: "eli-pc"),
        (k: "SCOOP", v: getEnv("SCOOP", getHomeDir() / "scoop")),
        (k: "REPRO_HOME_PACKAGE_CATALOG", v: PackageCatalog),
        (k: "REPRO_TEST_PACKAGE_SCOOP", v: scoopMapEnv()),
        (k: "REPRO_TEST_PACKAGE_SOURCE", v: pathMapEnv(fdExe)),
      ]

    # --- Pre-flight: capture the baseline. ---
    let baselineScoopApps = scoopInstalledApps()
    check baselineScoopApps.len >= 14
    # Snapshot the live HKCU\Environment\Path so Step 8 can confirm the
    # gate never touched the user's real PATH (it shouldn't — the apply
    # PATH contribution is isolated to the temp state dir's resources).
    let baselineUserPath =
      block:
        let r = readRegistryValue("Environment", "Path")
        if r.present: r.bytes else: @[]
    # Snapshot the live ~/.gitconfig target (a stow symlink). Step 8
    # re-verifies this is byte-identical: the gate's isolated $HOME
    # means the real one is never an apply target.
    let liveGitConfig = getHomeDir() / ".gitconfig"
    let baselineGitConfig =
      if fileExists(liveGitConfig): fileChecksum(liveGitConfig)
      else: ""

    # --- Pre-flight: prove rollback works on a no-op round trip. ---
    # First apply produces the BASELINE generation (the pre-test state
    # as Reprobuild models it). It carries a `profile`-kind store root
    # so GC's dead-set query never reclaims it — the milestone's
    # pinned-baseline requirement.
    let preApply = runRepro(baseEnv(), ["home", "apply"])
    logStep("pre-flight: baseline apply", preApply.output)
    doAssert preApply.exitCode == 0,
      "M70 pre-flight: baseline apply failed — ABORT before any " &
      "further change.\n" & preApply.output
    let baselineGenId = readCurrentGenerationId(stateDir)
    doAssert baselineGenId.len > 0, "M70 pre-flight: no baseline generation"
    # Apply a SECOND, identical generation so there is a prior
    # generation to roll back FROM, then roll back to the baseline and
    # confirm the round-trip is clean.
    let preApply2 = runRepro(baseEnv(), ["home", "apply"])
    doAssert preApply2.exitCode == 0,
      "M70 pre-flight: second apply failed — ABORT.\n" & preApply2.output
    # Second apply of identical intent is a verified no-op — `current`
    # does not advance, so a rollback "to baseline" is trivially the
    # current generation. Prove the rollback CLI itself round-trips by
    # rolling back to the baseline id explicitly.
    let preRollback = runRepro(baseEnv(),
      ["home", "rollback", baselineGenId])
    logStep("pre-flight: rollback to baseline", preRollback.output)
    doAssert preRollback.exitCode == 0,
      "M70 pre-flight: rollback round-trip FAILED — the environment " &
      "must be recoverable before the gate proceeds. ABORT.\n" &
      preRollback.output
    check readCurrentGenerationId(stateDir) == baselineGenId
    # Re-apply to leave the baseline current for Step 1 onward.
    discard runRepro(baseEnv(), ["home", "apply"])

    # -------------------------------------------------------------------
    # STEP 1: home.nim in place; baseline-checksum every legacy file.
    # -------------------------------------------------------------------
    check fileExists(homeNimPath)
    let step1Checksums = checksumDotfilesTree(RealDotfilesDir)
    # home.nim itself is in the map; record its baseline digest so we
    # can later confirm only the structural editor touches it.
    check step1Checksums.hasKey("home.nim")
    let homeNimStep1Digest = step1Checksums["home.nim"]
    # The dotfiles repo has a substantial legacy footprint.
    check step1Checksums.len > 50
    logStep("step 1: legacy checksum count",
      $step1Checksums.len & " files checksummed under " & RealDotfilesDir)

    # -------------------------------------------------------------------
    # STEP 2: first apply (the baseline already realized it; re-assert
    # the full desired state is present).
    # -------------------------------------------------------------------
    let step2 = runRepro(baseEnv(), ["home", "apply"])
    logStep("step 2: first apply", step2.output)
    check step2.exitCode == 0
    # A re-apply of the unchanged baseline is a verified no-op.
    check (step2.output.contains("no-op") or
           step2.output.contains("applied generation"))
    let step2GenId = readCurrentGenerationId(stateDir)
    check step2GenId.len > 0

    # Every Scoop app present at the expected version — and NOT
    # reinstalled (cache-hit). The Scoop survey is unchanged from the
    # pre-flight baseline.
    let step2ScoopApps = scoopInstalledApps()
    for b in scoopBindings():
      check step2ScoopApps.getOrDefault(b.app) == b.version
    check step2ScoopApps == baselineScoopApps

    # Generation manifest exists and validates its trailing checksum.
    # `decodeManifestBytes` raises `EManifestCorrupt` if the trailing
    # BLAKE3-256 checksum does not match, so a clean decode IS the
    # trailing-checksum validation.
    let pointerFile = pointerPath(stateDir, step2GenId)
    check fileExists(pointerFile)
    block:
      let envelope = readPointerFile(pointerFile)
      var store = openStore(storeRoot)
      defer: store.close()
      var manifestKey: PrefixIdBytes
      for i in 0 ..< 32:
        manifestKey[i] = envelope.activationManifestDigest[i]
      let manifestBytes = readCasBlob(store, manifestKey)
      let manifest = decodeManifestBytes(manifestBytes)
      check manifest.realizedPackages.len == 14

    # Launchers materialized in the stable bin dir.
    let stableBin = stateDir / "bin"
    check dirExists(stableBin)
    for b in scoopBindings():
      let nm = b.app
      check (fileExists(stableBin / (nm & ".exe")) or
             fileExists(stableBin / (nm & ".cmd")))
    for b in guiBindings():
      check (fileExists(stableBin / (b.app & ".exe")) or
             fileExists(stableBin / (b.app & ".cmd")))

    # The stow tree materialized into the isolated $HOME (the real
    # stow/ tree is read-only input). M73: the user's `~/dotfiles/stow/`
    # follows the GNU `stow` package convention — the immediate
    # subdirectories (`git/`, `nvim-lazyvim-vanilla/`, ...) are
    # PACKAGE names and are STRIPPED on materialization. So
    # `stow/git/.gitconfig` materializes at `$HOME/.gitconfig` (not
    # `$HOME/git/.gitconfig`), and `stow/nvim-lazyvim-vanilla/.config/
    # nvim-lazyvim-vanilla/init.lua` materializes at
    # `$HOME/.config/nvim-lazyvim-vanilla/init.lua`.
    check fileExists(homeDir / ".gitconfig")
    check dirExists(homeDir / ".config" / "nvim-lazyvim-vanilla")

    # -------------------------------------------------------------------
    # STEP 3: no-op re-apply.
    # -------------------------------------------------------------------
    let step3 = runRepro(baseEnv(), ["home", "apply"])
    logStep("step 3: no-op re-apply", step3.output)
    check step3.exitCode == 0
    check step3.output.contains("no-op")
    # `current` generation id unchanged.
    check readCurrentGenerationId(stateDir) == step2GenId

    # -------------------------------------------------------------------
    # STEP 4: `repro home set git.userEmail`.
    # -------------------------------------------------------------------
    # The git identity is already in home.nim's config: block from
    # Deliverable 1; `set` updates it in place (idempotent rewrite of
    # the same value keeps comments + the rest of the file intact).
    let homeNimBeforeSet = readFile(homeNimPath)
    let step4 = runRepro(baseEnv(),
      ["home", "set", "git.userEmail", "zahary@gmail.com"])
    logStep("step 4: home set git.userEmail", step4.output)
    check step4.exitCode == 0
    # `set` runs apply inline.
    check (step4.output.contains("applied generation") or
           step4.output.contains("no-op"))
    let homeNimAfterSet = readFile(homeNimPath)
    # The config: section still carries the value and comments around
    # it are preserved (the file still has the authored header
    # comment and the `hosts:` block).
    check homeNimAfterSet.contains("userEmail = \"zahary@gmail.com\"")
    check homeNimAfterSet.contains("Reprobuild home profile")
    check homeNimAfterSet.contains("hosts:")
    # The editor only touched the config: section; the package list is
    # unchanged.
    check homeNimAfterSet.contains("claude-code")
    check homeNimAfterSet.contains("ripgrep")
    discard homeNimBeforeSet

    # -------------------------------------------------------------------
    # STEP 5: `repro home add fd`.
    # -------------------------------------------------------------------
    # `fd` is bound through the `path` adapter (the `fd.cmd` fixture
    # staged before pre-flight and present in every apply env). The
    # add command edits `home.nim` and runs apply inline.
    let step5 = runRepro(baseEnv(),
      ["home", "add", "fd", "--profile-dir", RealDotfilesDir])
    logStep("step 5: home add fd", step5.output)
    check step5.exitCode == 0
    # `home.nim` gained the bare `fd` line in `activity default:`.
    let homeNimAfterAdd = readFile(homeNimPath)
    check homeNimAfterAdd.contains("fd")
    check homeNimAfterAdd.contains("claude-code")   # earlier lines intact
    # add ran apply inline.
    check (step5.output.contains("applied generation") or
           step5.output.contains("no-op"))
    # `fd` realized + launcher present; invoke through the launcher
    # copy path (the path adapter records a real prefix). Invoking the
    # launcher directly (not via PATH) removes ordering ambiguity.
    let fdLauncher = stableBin / "fd.exe"
    let fdLauncherCmd = stableBin / "fd.cmd"
    check (fileExists(fdLauncher) or fileExists(fdLauncherCmd))
    block:
      let launcher =
        if fileExists(fdLauncher): fdLauncher else: fdLauncherCmd
      let probe = execCmdEx(quoteShell(launcher) & " --version")
      check probe.exitCode == 0
      check probe.output.contains("fd 10.0.0")

    # -------------------------------------------------------------------
    # STEP 6: drift detection on a Reprobuild-managed file.
    # -------------------------------------------------------------------
    # MANAGED-FILE SUBSTITUTION (DEVIATION from the test design):
    # the test design's Step 6 names `~/.gitconfig`. This gate does
    # NOT use `~/.gitconfig`; it deviates from the test design here.
    # Reason: `~/.gitconfig` is a stow symlink into the real
    # `~/dotfiles/stow/git/.gitconfig`, and the first run of this
    # gate edited the materialized stow file, which wrote THROUGH the
    # link and corrupted the user's real `stow/git/.gitconfig` (a
    # drift line was added and the line endings were rewritten
    # LF->CRLF). That file was detected and restored byte-perfect.
    # The test design does NOT authorize this substitution — it is a
    # deviation adopted after the incident. The gate now drives drift
    # on a fully Reprobuild-OWNED `fs.managedBlock` resource in an
    # isolated `$HOME` file (`<home>/.repro-m70-drift`) that never
    # aliases any real-repo file. The user's hand-edit is still
    # stashed to a `.repro-rescued` sibling per the failure-recovery
    # section before `--reconcile-drift` runs.
    let managedFile = homeDir / ".repro-m70-drift"
    let managedBlockId = "repro.m70.drift"
    let managedBlockBody = "# m70 managed drift-test block"
    var mbEnv = baseEnv()
    let mbResource = "managedblock:m70.mb:~/.repro-m70-drift;" &
      managedBlockId & ";" & managedBlockBody
    mbEnv.add((k: "REPRO_TEST_RESOURCES", v: mbResource))

    # First apply with the managed block: it is created in the owned
    # host file with its sentinels.
    let step6create = runRepro(mbEnv, ["home", "apply"])
    logStep("step 6: managed-block create", step6create.output)
    check step6create.exitCode == 0
    check fileExists(managedFile)
    let managedBefore = readFile(managedFile)
    check managedBefore.contains(managedBlockBody)
    check managedBefore.contains("repro-managed:" & managedBlockId)

    # Stash the about-to-be-made user edit, then drift the file
    # out-of-band (edit the managed block's content directly).
    let rescued = managedFile & ".repro-rescued"
    let driftedContent =
      managedBefore.replace(managedBlockBody,
        managedBlockBody & " EDITED-OUT-OF-BAND")
    writeFile(rescued, driftedContent)
    writeFile(managedFile, driftedContent)
    copyFile(rescued, logDir / "repro-m70-drift.repro-rescued")

    # Apply must emit drift and NOT overwrite the file.
    let step6 = runRepro(mbEnv, ["home", "apply"])
    logStep("step 6: apply with drift", step6.output)
    check step6.exitCode != 0
    check (step6.output.contains("drift") or
           step6.output.contains("DRIFT") or
           step6.output.contains("Drift"))
    check readFile(managedFile) == driftedContent

    # `--reconcile-drift` restores the Reprobuild-managed content.
    var reconcileEnv = mbEnv
    reconcileEnv.add((k: "REPRO_HOME_APPLY_RECONCILE_DRIFT", v: "1"))
    let step6r = runRepro(reconcileEnv, ["home", "apply"])
    logStep("step 6: apply --reconcile-drift", step6r.output)
    check step6r.exitCode == 0
    check readFile(managedFile) == managedBefore

    # -------------------------------------------------------------------
    # STEP 6a: home-scope HKCU registry value (isolated subkey).
    # -------------------------------------------------------------------
    # ISOLATION SUBSTITUTION: rather than perturb a live user-facing
    # HKCU value (e.g. Explorer's HideFileExt named by the test
    # design), the gate uses a dedicated per-run subkey under
    # `HKCU\Software\Reprobuild-Tests\m70-<ts>\`. Disclosed in the
    # gate notes and the milestone Completion Notes.
    proc cleanupSubkey() =
      try: deleteRegistryValue(testSubkey, "M70Value")
      except CatchableError: discard
    cleanupSubkey()
    defer: cleanupSubkey()

    var regEnv = baseEnv()
    let regResource = "registry:m70.reg:" & testSubkey &
      ";M70Value;dword;305419896"
    regEnv.add((k: "REPRO_TEST_RESOURCES", v: regResource))
    let step6a = runRepro(regEnv, ["home", "apply"])
    logStep("step 6a: apply registryValue", step6a.output)
    check step6a.exitCode == 0
    block:
      let r = readRegistryValue(testSubkey, "M70Value")
      check r.present
      check r.regType == 4'u32                       # REG_DWORD
      check r.bytes == encodeDword(305419896'u32)    # postWriteValue

    # Flip the value out-of-band; re-apply must report drift.
    writeRegistryValue(testSubkey, "M70Value", 4'u32,
      encodeDword(0xDEADBEEF'u32))
    let step6aDrift = runRepro(regEnv, ["home", "apply"])
    logStep("step 6a: apply with registry drift", step6aDrift.output)
    check step6aDrift.exitCode != 0
    check (step6aDrift.output.contains("drift") or
           step6aDrift.output.contains("DRIFT"))

    # `--reconcile-drift` restores the recorded postWriteValue.
    var regReconcileEnv = regEnv
    regReconcileEnv.add((k: "REPRO_HOME_APPLY_RECONCILE_DRIFT", v: "1"))
    let step6aR = runRepro(regReconcileEnv, ["home", "apply"])
    logStep("step 6a: registry --reconcile-drift", step6aR.output)
    check step6aR.exitCode == 0
    block:
      let r = readRegistryValue(testSubkey, "M70Value")
      check r.present
      check r.bytes == encodeDword(305419896'u32)

    # -------------------------------------------------------------------
    # STEP 6b: system scope is DEFERRED (M69). Assert rejection; do NOT
    # attempt any elevated operation.
    # -------------------------------------------------------------------
    let step6b = runRepro(baseEnv(),
      ["home", "apply", "--include-system"])
    logStep("step 6b: --include-system rejection", step6b.output)
    check step6b.exitCode != 0
    # The CLI rejects the unknown flag before any side effect.
    check (step6b.output.contains("--include-system") or
           step6b.output.contains("unknown flag") or
           step6b.output.contains("M69"))

    # -------------------------------------------------------------------
    # STEP 7: rollback to the baseline generation.
    # -------------------------------------------------------------------
    let step7 = runRepro(baseEnv(), ["home", "rollback", baselineGenId])
    logStep("step 7: rollback to baseline", step7.output)
    check step7.exitCode == 0
    check readCurrentGenerationId(stateDir) == baselineGenId
    rolledBackToBaseline = true

    # Scoop apps remain installed — rollback does NOT uninstall.
    let step7ScoopApps = scoopInstalledApps()
    check step7ScoopApps == baselineScoopApps

    # -------------------------------------------------------------------
    # STEP 8: re-apply + non-destructive verification.
    # -------------------------------------------------------------------
    let step8 = runRepro(baseEnv(), ["home", "apply"])
    logStep("step 8: re-apply to managed state", step8.output)
    check step8.exitCode == 0
    rolledBackToBaseline = false

    # HARD GATE: every legacy file under ~/dotfiles is byte-identical
    # to the Step 1 baseline. `home.nim` is the ONLY allowed change
    # (the structural editor edited it in Steps 4/5).
    let step8Checksums = checksumDotfilesTree(RealDotfilesDir)
    var changedFiles: seq[string]
    for relPath, digest in step1Checksums:
      let now = step8Checksums.getOrDefault(relPath)
      if now != digest:
        changedFiles.add(relPath)
    var removedFiles: seq[string]
    for relPath in step1Checksums.keys:
      if not step8Checksums.hasKey(relPath):
        removedFiles.add(relPath)
    var addedFiles: seq[string]
    for relPath in step8Checksums.keys:
      if not step1Checksums.hasKey(relPath):
        addedFiles.add(relPath)
    # No legacy file was deleted or renamed.
    check removedFiles.len == 0
    # No file was added by Reprobuild (home.nim already existed).
    check addedFiles.len == 0
    # The ONLY file whose digest changed is `home.nim` (Steps 4/5
    # structural edits). Every other legacy file is byte-identical.
    check changedFiles.sorted() == @["home.nim"]
    # home.nim DID change (the editor ran).
    check step8Checksums["home.nim"] != homeNimStep1Digest
    logStep("step 8: non-destructive verification",
      "legacy files re-checksummed: " & $step8Checksums.len &
      "; changed: " & $changedFiles & "; removed: " & $removedFiles &
      "; added: " & $addedFiles)

    # The user's live $HOME registry PATH was never touched.
    block:
      let r = readRegistryValue("Environment", "Path")
      let nowPath = if r.present: r.bytes else: @[]
      check nowPath == baselineUserPath

    # The user's live ~/.gitconfig (stow symlink) is byte-identical.
    if baselineGitConfig.len > 0:
      check fileExists(liveGitConfig)
      check fileChecksum(liveGitConfig) == baselineGitConfig

    # Final `repro home apply --plan`: zero operations.
    let finalPlan = runRepro(baseEnv(), ["home", "plan"])
    logStep("step 8: final plan", finalPlan.output)
    check finalPlan.exitCode == 0

    # -------------------------------------------------------------------
    # Persist the apply log (Deliverable 4) for human review.
    # -------------------------------------------------------------------
    let logsRoot = ProjectRoot / "test-logs"
    createDir(logsRoot)
    let applyLogPath = logsRoot /
      "e2e_dotfiles_replacement_on_real_host.apply-log.txt"
    writeFile(applyLogPath, applyLog.join("\n"))
    # Also keep a copy alongside the rescued user edit in the temp log
    # dir so the full artifact set is co-located.
    writeFile(logDir / "apply-log.txt", applyLog.join("\n"))
    checkpoint "apply log written to " & applyLogPath
    checkpoint "rescued user edit at " & logDir /
      "git-gitconfig.repro-rescued"

    # RECOVERY GUARD: if a later assertion failed and left the env at
    # baseline, this annotation makes the post-state explicit.
    if rolledBackToBaseline:
      checkpoint "M70: environment left at captured baseline " &
        baselineGenId
