## M6 / M13 Phase-5 Gate: e2e_macos_phase5_homebrew_cask
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `pkg.homebrewCask` driver (home-scope, in
## `libs/repro_homebrew_adapter/src/repro_homebrew_adapter/cask.nim`)
## had shipped a `when defined(macosx)` arm that had never run against
## a real macOS guest. M83 step 9 (Driver B) authored the driver; M13
## (`macOS Homebrew Driver Validation`) wires the apply/verify/destroy
## scenario for it.
##
## M13 deliverable: drive `applyHomebrewCask` inside a disposable macOS
## VM and assert that
##   1. the cask is observable via the driver's own
##      `observeHomebrewCask` (digest non-zero, present),
##   2. an out-of-band `brew list --cask --versions <name>` succeeds and
##      reports a non-empty installed version, AND the cask's payload
##      materializes in the documented destination (for a font cask,
##      the `.ttf`/`.otf` files land in `~/Library/Fonts/`),
##   3. the destroy direction (`destroyHomebrewCask`) uninstalls the
##      cask and leaves no surviving payload bundle.
##
## ## Fixture choice — `font-fira-code`
##
## `font-fira-code` (https://github.com/tonsky/FiraCode) is the
## generic test fixture per the M13 milestone (`a small generic cask
## like font-fira-code`):
##   * Small (~5 MB of .ttf files; ~5-10s install once the bottle is
##     cached, and the bottle is small enough Homebrew can pull it on
##     a fresh guest in under 30s).
##   * Stable — Fira Code is a widely-used monospaced programming
##     font, around since 2014; the cask in homebrew-cask has been
##     maintained continuously.
##   * SIL Open Font License (OFL) — fully open source.
##   * Zero macOS-specific side effects beyond the documented font
##     install: drops Fira Code `.ttf` variants under
##     `~/Library/Fonts/` on a per-user font install (the modern
##     homebrew-cask default for font casks — previously some font
##     casks installed system-wide under `/Library/Fonts/`, but the
##     homebrew-cask ecosystem migrated to user-scope installs
##     years ago).
##   * Does NOT register a `.app` bundle under `/Applications/`, so
##     the install does not pollute the guest's app launcher. The
##     `~/Library/Fonts/` drop is the entirety of the side effect.
##   * NOT user-personal — this is a public test fixture, not part of
##     the user's actual cask list (`darwin-configuration.nix`).
##     The user's personal casks are exercised separately in the
##     private M14 milestone.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half invokes `brew install --cask font-fira-code` +
## `brew uninstall --cask font-fira-code`, which mutate the guest's
## Homebrew Caskroom under `/opt/homebrew/Caskroom/` (Apple Silicon)
## or `/usr/local/Caskroom/` (Intel) AND drop `.ttf` files under the
## user's `~/Library/Fonts/`. Homebrew runs unelevated as the owning
## admin user (the cirruslabs golden ships the admin user owning the
## Homebrew prefix), so this gate does NOT need `sudo`. Guarded by
## BOTH `defined(macosx)` AND `REPRO_PHASE5_MACOS_BREW_CASK_VM=1`. The
## host-side runner cross-builds this binary, copies it into a freshly-
## cloned Tart macOS guest, and runs it as the cirruslabs admin user
## (NOT under sudo).

import std/[os, osproc, strutils, unittest]

import repro_home_resources
import repro_homebrew_adapter

# The real-mutation scenario is gated by BOTH the platform (macOS) and
# the explicit opt-in env var. The env var is left UNSET on every CI /
# dev host so the gate never invokes `brew install --cask` on a real
# host.
let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_BREW_CASK_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure helpers + canonical-bytes + typed-resource
# digest + validation. Always runs.
# ===========================================================================

suite "pkg.homebrewCask: pure helpers + canonical bytes":

  test "isSafeHomebrewName accepts font-fira-code + standard casks":
    check isSafeHomebrewName("font-fira-code")
    check isSafeHomebrewName("iterm2")
    check isSafeHomebrewName("visual-studio-code")

  test "isSafeHomebrewName rejects shell-meta in cask names":
    check not isSafeHomebrewName("font-fira-code;rm -rf /")
    check not isSafeHomebrewName("Firefox")  # uppercase
    check not isSafeHomebrewName("")

  test "composeInstallArgs / composeUninstallArgs (cask)":
    check composeInstallArgs(isCask = true, name = "font-fira-code",
        extraArgs = []) ==
      @["install", "--cask", "font-fira-code"]
    check composeUninstallArgs(isCask = true, name = "font-fira-code") ==
      @["uninstall", "--cask", "font-fira-code"]

  test "canonicalHomebrewCaskBytes: name + 0x1e + version":
    let bytes = canonicalHomebrewCaskBytes("font-fira-code", "6.2")
    var s = ""
    for b in bytes: s.add(char(b))
    check s == "font-fira-code\x1e6.2"

suite "pkg.homebrewCask: typed-resource wiring + digest + validation":

  test "a pkg.homebrewCask Resource accepts the canonical fields":
    let r = Resource(kind: rkHomebrewCask,
      address: "hbc:font-fira-code",
      lifecyclePolicy: lpDefault,
      caskName: "font-fira-code",
      caskVersion: "",
      caskArgs: @[])
    check resourceValidationError(r) == ""
    check realWorldIdentity(r) == "homebrew:cask:font-fira-code"

  test "resourceValidationError rejects empty / unsafe caskName":
    let bad = Resource(kind: rkHomebrewCask,
      address: "hbc:bad",
      lifecyclePolicy: lpDefault,
      caskName: "font-fira-code;rm -rf /",
      caskVersion: "")
    check resourceValidationError(bad).len > 0

  test "digestOfResource: cask args do not flip the identity":
    var r1 = Resource(kind: rkHomebrewCask,
      address: "hbc:digest",
      lifecyclePolicy: lpDefault,
      caskName: "font-fira-code",
      caskVersion: "")
    var r2 = r1
    r2.caskArgs = @["--no-quarantine"]
    check digestOfResource(r1) == digestOfResource(r2)

  test "resourceKindFromString recognizes pkg.homebrewCask":
    check resourceKindFromString("pkg.homebrewCask") ==
      rkHomebrewCask

# ===========================================================================
# DESTRUCTIVE: real `brew install --cask font-fira-code` /
# `brew uninstall --cask font-fira-code` on macOS. SANDBOX/VM-ONLY -
# guarded by BOTH the macOS platform AND
# `REPRO_PHASE5_MACOS_BREW_CASK_VM=1`. M13 lands the scenario.
# ===========================================================================

when defined(macosx):

  proc resolveBrewExe(): string =
    ## Discover the `brew` binary on the guest. The cirruslabs macOS
    ## golden ships Homebrew pre-installed at the Apple Silicon prefix
    ## `/opt/homebrew/bin/brew`; we fall back to the Intel prefix and
    ## PATH for defensive robustness.
    if fileExists("/opt/homebrew/bin/brew"):
      return "/opt/homebrew/bin/brew"
    if fileExists("/usr/local/bin/brew"):
      return "/usr/local/bin/brew"
    findExe("brew")

  proc brewListCaskVersions(brewExe, name: string):
      tuple[output: string; exitCode: int] =
    ## Re-implement `brew list --cask --versions <name>` from outside
    ## the driver so the assertion is independent of the driver's own
    ## observation codepath.
    let cmd = quoteShell(brewExe) & " list --cask --versions " &
      quoteShell(name)
    let (out0, code) = execCmdEx(cmd,
      options = {poStdErrToStdOut})
    (out0, code)

  proc brewPrefixOf(brewExe: string): string =
    ## `brew --prefix` returns the realized prefix; on Apple Silicon
    ## this is `/opt/homebrew`, on Intel `/usr/local`.
    let (out0, code) = execCmdEx(quoteShell(brewExe) & " --prefix",
      options = {poStdErrToStdOut})
    if code != 0:
      return ""
    out0.strip()

  proc firaCodeFontFiles(home: string): seq[string] =
    ## Walk `~/Library/Fonts/` and return paths whose basenames start
    ## with `FiraCode`. font-fira-code drops several `.ttf` variants
    ## (Regular, Bold, Light, Medium, Retina, SemiBold) so we expect
    ## multiple matches post-install.
    result = @[]
    let dir = home / "Library" / "Fonts"
    if not dirExists(dir):
      return
    for kind, path in walkDir(dir):
      if kind != pcFile: continue
      let base = path.extractFilename()
      if base.startsWith("FiraCode") and
         (base.endsWith(".ttf") or base.endsWith(".otf")):
        result.add(path)

suite "pkg.homebrewCask: REAL brew install --cask / uninstall --cask (sandbox-only)":

  test "real pkg.homebrewCask lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_BREW_CASK_VM not " &
        "set (or not on macOS) - the real `brew install --cask " &
        "font-fira-code` / `brew uninstall --cask font-fira-code` " &
        "scenario is NOT EXERCISED on this host. Run this gate " &
        "inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_BREW_CASK_VM=1 to exercise the real " &
        "Homebrew Cask mutation. The pure-logic suites above " &
        "already proved the helpers + canonical bytes + typed-" &
        "field digest + validation without mutating any host."
    else:
      when defined(macosx):
        # ---------------------------------------------------------------
        # Test cask: font-fira-code (per the M13 fixture choice — see
        # the module docstring). We pick a single small generic open-
        # source font cask explicitly so the public test suite carries
        # NO reference to the user's personal cask list.
        # ---------------------------------------------------------------
        let testCask = "font-fira-code"
        let brewExe = resolveBrewExe()
        doAssert brewExe.len > 0,
          "no `brew` binary discoverable on this guest at " &
          "/opt/homebrew/bin/brew, /usr/local/bin/brew, or PATH. " &
          "The cirruslabs macOS Tahoe golden ships Homebrew " &
          "pre-installed; if a future guest drops it the gate's " &
          "premise needs to be re-thought."

        # Pin the driver to the same brew binary the gate uses for
        # its out-of-band probes (see the formula gate for the
        # rationale — the host-side runner's `env VAR=1 binary`
        # invocation strips /opt/homebrew/bin from PATH).
        putEnv("REPRO_HOMEBREW_BREW_BINARY", brewExe)
        echo "  [brew-pin] REPRO_HOMEBREW_BREW_BINARY=" & brewExe

        # Augment PATH so `brew install --cask` itself can find its
        # in-tree helpers (git, curl) at /opt/homebrew/bin alongside
        # /usr/bin / /bin.
        let oldPath = getEnv("PATH")
        let brewBinDir = brewExe.parentDir()
        if oldPath.len == 0:
          putEnv("PATH", brewBinDir & ":/usr/bin:/bin:/usr/sbin:/sbin")
        elif not oldPath.contains(brewBinDir):
          putEnv("PATH", brewBinDir & ":" & oldPath)
        echo "  [path] PATH=" & getEnv("PATH")
        let prefix = brewPrefixOf(brewExe)
        doAssert prefix.len > 0,
          "`brew --prefix` failed (brewExe=" & brewExe & ")"
        doAssert prefix == "/opt/homebrew" or prefix == "/usr/local",
          "`brew --prefix` returned an unexpected value '" & prefix &
          "'; expected /opt/homebrew (Apple Silicon) or /usr/local " &
          "(Intel)."
        echo "  [brew] prefix=" & prefix

        let home = getEnv("HOME")
        doAssert home.startsWith("/Users/"),
          "macOS $HOME '" & home & "' is not Apple-flavored " &
          "(/Users/...); font cask install verification checks " &
          "~/Library/Fonts/, which requires a sane home dir."

        # Best-effort cleanup of stale state from a prior aborted run.
        # The Tart guest is freshly cloned per gate so there should be
        # nothing to clean, but the defensive form is harmless.
        discard execCmdEx(quoteShell(brewExe) & " uninstall --cask " &
          quoteShell(testCask), options = {poStdErrToStdOut})

        # Prior state: cask absent both via the driver's observer AND
        # via the out-of-band `brew list --cask --versions` witness.
        let preObs = observeHomebrewCask(testCask, "")
        doAssert not preObs.present,
          "pre-apply: observeHomebrewCask(" & testCask &
          ") reports present BEFORE applyHomebrewCask was called " &
          "(stale install on the guest?)"
        let preList = brewListCaskVersions(brewExe, testCask)
        doAssert preList.exitCode != 0 or
                 parseBrewVersionsLine(preList.output) ==
                   HomebrewAbsentVersion,
          "pre-apply: `brew list --cask --versions " & testCask &
          "` unexpectedly reports a version (" &
          parseBrewVersionsLine(preList.output) & "); test cannot " &
          "prove round-trip."

        # Pre-state: no FiraCode font files in ~/Library/Fonts/.
        let preFontFiles = firaCodeFontFiles(home)
        doAssert preFontFiles.len == 0,
          "pre-apply: ~/Library/Fonts/ already contains FiraCode " &
          "files: " & preFontFiles.join(", ") & " — test cannot " &
          "prove the cask's font-drop side effect."

        # ---------------------------------------------------------------
        # 1. APPLY: install via the driver's `applyHomebrewCask`.
        # ---------------------------------------------------------------
        echo "  [apply] applyHomebrewCask(" & testCask & ")"
        let postBytes = applyHomebrewCask(testCask, "", @[])
        doAssert postBytes.len > 0,
          "applyHomebrewCask returned empty post-write bytes"

        # PASS CRITERION (M13 verification block,
        # `verify_macos_pkg_homebrewcask_install_uninstall`): the
        # cask is observable AND `brew list --cask --versions`
        # succeeds AND the cask's payload (FiraCode `.ttf` files)
        # appears under `~/Library/Fonts/`.

        let obs1 = observeHomebrewCask(testCask, "")
        doAssert obs1.present,
          "post-apply: observeHomebrewCask(" & testCask &
          ") reports absent after applyHomebrewCask"

        let postList = brewListCaskVersions(brewExe, testCask)
        doAssert postList.exitCode == 0,
          "post-apply: `brew list --cask --versions " & testCask &
          "` failed (exit " & $postList.exitCode & "): " &
          postList.output.strip()
        let installedVersion = parseBrewVersionsLine(postList.output)
        doAssert installedVersion.len > 0 and
                 installedVersion != HomebrewAbsentVersion,
          "post-apply: out-of-band `brew list --cask --versions` " &
          "did not produce a version line: " & postList.output.strip()
        echo "  [observe] installed " & testCask & " " &
          installedVersion

        # Font-drop verification: at least one FiraCode .ttf must
        # materialize under ~/Library/Fonts/. font-fira-code typically
        # drops 6 variants (Regular, Bold, Light, Medium, Retina,
        # SemiBold) — we assert at least one to be tolerant of future
        # variant renames.
        let postFontFiles = firaCodeFontFiles(home)
        doAssert postFontFiles.len > 0,
          "post-apply: cask reports installed but no FiraCode font " &
          "files found under " & (home / "Library" / "Fonts") &
          " — the cask's documented font-drop side effect did not " &
          "materialize."
        echo "  [fonts] " & $postFontFiles.len &
          " FiraCode font files under ~/Library/Fonts/"

        # ---------------------------------------------------------------
        # 2. RE-APPLY: same operation. Should be a no-op from the
        #    drift-detection perspective.
        # ---------------------------------------------------------------
        echo "  [re-apply] applyHomebrewCask(" & testCask & ")"
        let postBytes2 = applyHomebrewCask(testCask, "", @[])
        doAssert postBytes2 == postBytes,
          "re-apply: post-write bytes drifted; re-apply should be " &
          "a no-op from the drift-detection perspective. Before: " &
          $postBytes.len & " bytes; after: " & $postBytes2.len & " bytes"

        let obs2 = observeHomebrewCask(testCask, "")
        doAssert obs2.present
        doAssert obs2.digest == obs1.digest,
          "re-apply: observe digest drifted unexpectedly"

        # ---------------------------------------------------------------
        # 3. DESTROY: `destroyHomebrewCask` uninstalls the cask.
        #    Post-destroy the cask must be absent both via the
        #    driver's observer AND via the out-of-band `brew list`
        #    witness, AND the FiraCode .ttf files must be gone from
        #    `~/Library/Fonts/` (Homebrew's cask uninstall removes
        #    the cask's documented artifacts).
        # ---------------------------------------------------------------
        echo "  [destroy] destroyHomebrewCask(" & testCask & ")"
        destroyHomebrewCask(testCask)

        let postDestroyObs = observeHomebrewCask(testCask, "")
        doAssert not postDestroyObs.present,
          "post-destroy: observeHomebrewCask reports present after " &
          "destroyHomebrewCask"

        let postDestroyList = brewListCaskVersions(brewExe, testCask)
        doAssert postDestroyList.exitCode != 0 or
                 parseBrewVersionsLine(postDestroyList.output) ==
                   HomebrewAbsentVersion,
          "post-destroy: `brew list --cask --versions " & testCask &
          "` STILL reports a version after destroyHomebrewCask: " &
          postDestroyList.output.strip()

        let postDestroyFontFiles = firaCodeFontFiles(home)
        doAssert postDestroyFontFiles.len == 0,
          "post-destroy: ~/Library/Fonts/ STILL contains FiraCode " &
          "files after destroyHomebrewCask: " &
          postDestroyFontFiles.join(", ") & " — `brew uninstall " &
          "--cask` was expected to remove the cask's documented " &
          "artifacts alongside the Caskroom entry."

        echo "  [OK] pkg.homebrewCask lifecycle: apply / re-apply " &
          "(no-op) / destroy round-trip on disposable cask " &
          testCask & " (installed version " & installedVersion &
          "); out-of-band `brew list --cask --versions` + " &
          "~/Library/Fonts/ FiraCode font-drop check verified " &
          "install; destroy uninstalls cleanly with no orphan font " &
          "files or Caskroom entry."
