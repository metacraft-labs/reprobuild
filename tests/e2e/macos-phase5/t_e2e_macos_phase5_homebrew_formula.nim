## M6 / M13 Phase-5 Gate: e2e_macos_phase5_homebrew_formula
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `pkg.homebrewFormula` driver (home-scope, in
## `libs/repro_homebrew_adapter/src/repro_homebrew_adapter/formula.nim`)
## had shipped a `when defined(macosx)` arm that had never run against
## a real macOS guest. M83 step 9 (Driver A) authored the driver; M13
## (`macOS Homebrew Driver Validation`) wires the apply/verify/destroy
## scenario for it.
##
## M13 deliverable: drive `applyHomebrewFormula` inside a disposable
## macOS VM and assert that
##   1. the formula is observable via the driver's own
##      `observeHomebrewFormula` (digest non-zero, present),
##   2. an out-of-band `brew list --formula --versions <name>` succeeds
##      and reports a non-empty installed version (proves the formula
##      is registered in Homebrew's Cellar, not just that the driver's
##      observer reports it), AND that the formula's primary binary is
##      reachable via `<brew-prefix>/bin/<name>` (the Cellar+symlink
##      shape Homebrew guarantees for CLI formulae),
##   3. the destroy direction (`destroyHomebrewFormula`) uninstalls the
##      formula and leaves no surviving Cellar entry or PATH symlink.
##
## ## Fixture choice — `jq`
##
## `jq` (https://github.com/jqlang/jq) is the generic test fixture
## per the M13 milestone (`a small stable open-source formula like
## jq or hello`):
##   * Small (~700 KB binary, ~2 MB Cellar entry; ~5-10s install on a
##     warm Homebrew cache).
##   * Stable — first released 2012; constant interface, no breaking
##     CLI changes in years; consumed by enormous numbers of shell
##     pipelines as a de-facto JSON CLI.
##   * MIT-licensed.
##   * Zero macOS-specific dependencies. Pure C; Homebrew's bottle
##     supports both Intel and Apple Silicon natively.
##   * Ships ONE binary (`jq`) under `<prefix>/bin/` — easy to assert
##     the post-install observation.
##   * NOT user-personal — this is a public test fixture, not part of
##     the user's actual package list (`darwin-configuration.nix`).
##     Picked from the broader open-source CLI ecosystem; the user's
##     personal Homebrew set (which is private to their dotfiles)
##     is exercised separately in the private M14 milestone.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half invokes `brew install jq` + `brew uninstall jq`,
## which mutate the guest's Homebrew Cellar under
## `/opt/homebrew/Cellar/` (Apple Silicon) or `/usr/local/Cellar/`
## (Intel). Homebrew runs unelevated as the owning admin user (the
## cirruslabs golden ships the admin user owning the Homebrew prefix
## per Apple Silicon convention), so this gate does NOT need `sudo`.
## Guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_BREW_FORMULA_VM=1`. The host-side runner
## cross-builds this binary, copies it into a freshly-cloned Tart macOS
## guest, and runs it as the cirruslabs admin user (NOT under sudo).

import std/[os, osproc, strutils, unittest]

import repro_home_resources
import repro_homebrew_adapter

# The real-mutation scenario is gated by BOTH the platform (macOS) and
# the explicit opt-in env var. The env var is left UNSET on every CI /
# dev host so the gate never invokes `brew install` on a real host.
let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_BREW_FORMULA_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure helpers + canonical-bytes + typed-resource
# digest + validation. Always runs.
# ===========================================================================

suite "pkg.homebrewFormula: pure helpers + canonical bytes":

  test "isSafeHomebrewName accepts jq + standard CLI formulae":
    check isSafeHomebrewName("jq")
    check isSafeHomebrewName("ripgrep")
    check isSafeHomebrewName("node@18")

  test "isSafeHomebrewName rejects shell-meta":
    check not isSafeHomebrewName("jq;rm -rf /")
    check not isSafeHomebrewName("Jq")     # uppercase
    check not isSafeHomebrewName("")

  test "parseBrewVersionsLine extracts the primary keg version":
    check parseBrewVersionsLine("jq 1.7.1") == "1.7.1"
    check parseBrewVersionsLine("") == HomebrewAbsentVersion
    check parseBrewVersionsLine("jq") == HomebrewAbsentVersion

  test "composeInstallArgs / composeUninstallArgs (formula)":
    check composeInstallArgs(isCask = false, name = "jq",
        extraArgs = []) ==
      @["install", "jq"]
    check composeUninstallArgs(isCask = false, name = "jq") ==
      @["uninstall", "jq"]

  test "canonicalHomebrewFormulaBytes: name + 0x1e + version":
    let bytes = canonicalHomebrewFormulaBytes("jq", "1.7.1")
    var s = ""
    for b in bytes: s.add(char(b))
    check s == "jq\x1e1.7.1"

suite "pkg.homebrewFormula: typed-resource wiring + digest + validation":

  test "a pkg.homebrewFormula Resource accepts the canonical fields":
    let r = Resource(kind: rkHomebrewFormula,
      address: "hb:jq",
      lifecyclePolicy: lpDefault,
      formulaName: "jq",
      formulaVersion: "",
      formulaArgs: @[])
    check resourceValidationError(r) == ""
    check realWorldIdentity(r) == "homebrew:formula:jq"

  test "resourceValidationError rejects empty / unsafe formulaName":
    let bad = Resource(kind: rkHomebrewFormula,
      address: "hb:bad",
      lifecyclePolicy: lpDefault,
      formulaName: "jq;rm -rf /",
      formulaVersion: "")
    check resourceValidationError(bad).len > 0

  test "digestOfResource: jq digest is stable / formula args do not flip":
    var r1 = Resource(kind: rkHomebrewFormula,
      address: "hb:digest",
      lifecyclePolicy: lpDefault,
      formulaName: "jq",
      formulaVersion: "")
    var r2 = r1
    r2.formulaArgs = @["--build-from-source"]
    check digestOfResource(r1) == digestOfResource(r2)

  test "resourceKindFromString recognizes pkg.homebrewFormula":
    check resourceKindFromString("pkg.homebrewFormula") ==
      rkHomebrewFormula

# ===========================================================================
# DESTRUCTIVE: real `brew install jq` / `brew uninstall jq` on macOS.
# SANDBOX/VM-ONLY - guarded by BOTH the macOS platform AND
# `REPRO_PHASE5_MACOS_BREW_FORMULA_VM=1`. M13 lands the scenario.
# ===========================================================================

when defined(macosx):

  proc resolveBrewExe(): string =
    ## Discover the `brew` binary on the guest. The cirruslabs macOS
    ## golden ships Homebrew pre-installed at the Apple Silicon prefix
    ## `/opt/homebrew/bin/brew`; we fall back to the Intel prefix and
    ## PATH for defensive robustness, then bail if no `brew` is on
    ## either.
    if fileExists("/opt/homebrew/bin/brew"):
      return "/opt/homebrew/bin/brew"
    if fileExists("/usr/local/bin/brew"):
      return "/usr/local/bin/brew"
    findExe("brew")

  proc brewListVersions(brewExe, name: string):
      tuple[output: string; exitCode: int] =
    ## Re-implement `brew list --formula --versions <name>` from
    ## outside the driver so the assertion is independent of the
    ## driver's own observation codepath. We want to PROVE the formula
    ## is registered with Homebrew, not just that the driver's
    ## observer reports it.
    let cmd = quoteShell(brewExe) & " list --formula --versions " &
      quoteShell(name)
    let (out0, code) = execCmdEx(cmd,
      options = {poStdErrToStdOut})
    (out0, code)

  proc brewPrefixOf(brewExe: string): string =
    ## `brew --prefix` returns the realized prefix; on Apple Silicon
    ## this is `/opt/homebrew`, on Intel `/usr/local`. We use it to
    ## locate the post-install symlink under `<prefix>/bin/<name>`.
    let (out0, code) = execCmdEx(quoteShell(brewExe) & " --prefix",
      options = {poStdErrToStdOut})
    if code != 0:
      return ""
    out0.strip()

suite "pkg.homebrewFormula: REAL brew install/uninstall (sandbox-only)":

  test "real pkg.homebrewFormula lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_BREW_FORMULA_VM " &
        "not set (or not on macOS) - the real `brew install jq` / " &
        "`brew uninstall jq` scenario is NOT EXERCISED on this " &
        "host. Run this gate inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_BREW_FORMULA_VM=1 to exercise the real " &
        "Homebrew mutation. The pure-logic suites above already " &
        "proved the helpers + canonical bytes + typed-field digest " &
        "+ validation without mutating any host."
    else:
      when defined(macosx):
        # ---------------------------------------------------------------
        # Test formula: jq (per the M13 fixture choice — see the
        # module docstring). We pick a single small generic open-
        # source CLI formula explicitly so the public test suite
        # carries NO reference to the user's personal package list.
        # ---------------------------------------------------------------
        let testFormula = "jq"
        let brewExe = resolveBrewExe()
        doAssert brewExe.len > 0,
          "no `brew` binary discoverable on this guest at " &
          "/opt/homebrew/bin/brew, /usr/local/bin/brew, or PATH. " &
          "The cirruslabs macOS Tahoe golden ships Homebrew " &
          "pre-installed; if a future guest drops it the gate's " &
          "premise needs to be re-thought (e.g. installing Homebrew " &
          "via the host-side runner's pre-test hook)."

        # Pin the driver to the same brew binary the gate uses for
        # its out-of-band probes. The cirruslabs guest's admin user
        # has /opt/homebrew/bin on PATH through the interactive
        # shell's `eval $(brew shellenv)` in `~/.zprofile`, but the
        # host-side runner invokes us via `env VAR=1 /tmp/<gate>`
        # which strictly preserves the passed-in environment — PATH
        # comes from the kernel-level inherited environment which
        # has only /usr/bin:/bin:/usr/sbin:/sbin, not /opt/homebrew/
        # bin. Setting REPRO_HOMEBREW_BREW_BINARY explicitly makes
        # the driver's `brewBinary()` discovery short-circuit to the
        # known path instead of falling back to a PATH search that
        # would miss /opt/homebrew/bin.
        putEnv("REPRO_HOMEBREW_BREW_BINARY", brewExe)
        echo "  [brew-pin] REPRO_HOMEBREW_BREW_BINARY=" & brewExe

        # Augment PATH so `brew install` itself can find its own
        # in-tree helpers (git, curl) at /opt/homebrew/bin alongside
        # /usr/bin / /bin. Same problem at the next level down: the
        # driver invokes `brew`, brew shells out to git/curl, those
        # bins are at /opt/homebrew/bin but PATH lost it.
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
          "(Intel). The gate is hard-keyed on these two install " &
          "prefixes — anything else means an exotic Homebrew layout " &
          "the gate has not been tested against."
        echo "  [brew] prefix=" & prefix

        # Best-effort cleanup of stale state from a prior aborted run.
        # The Tart guest is freshly cloned per gate so there should be
        # nothing to clean, but the defensive form is harmless.
        discard execCmdEx(quoteShell(brewExe) & " uninstall " &
          quoteShell(testFormula), options = {poStdErrToStdOut})

        # Prior state: jq is absent both via the driver's observer
        # AND via the out-of-band `brew list --formula --versions`
        # witness.
        let preObs = observeHomebrewFormula(testFormula, "")
        doAssert not preObs.present,
          "pre-apply: observeHomebrewFormula(" & testFormula &
          ") reports present BEFORE applyHomebrewFormula was called " &
          "(stale install on the guest?)"
        let preList = brewListVersions(brewExe, testFormula)
        doAssert preList.exitCode != 0 or
                 parseBrewVersionsLine(preList.output) ==
                   HomebrewAbsentVersion,
          "pre-apply: `brew list --formula --versions " & testFormula &
          "` unexpectedly reports a version (" &
          parseBrewVersionsLine(preList.output) & "); test cannot " &
          "prove round-trip."

        # ---------------------------------------------------------------
        # 1. APPLY: install via the driver's `applyHomebrewFormula`.
        # ---------------------------------------------------------------
        echo "  [apply] applyHomebrewFormula(" & testFormula & ")"
        let postBytes = applyHomebrewFormula(testFormula, "", @[])
        doAssert postBytes.len > 0,
          "applyHomebrewFormula returned empty post-write bytes"

        # PASS CRITERION (M13 verification block,
        # `verify_macos_pkg_homebrewformula_install_uninstall`): the
        # formula is observable AND `brew list --formula --versions`
        # succeeds AND `<prefix>/bin/<name>` exists.

        let obs1 = observeHomebrewFormula(testFormula, "")
        doAssert obs1.present,
          "post-apply: observeHomebrewFormula(" & testFormula &
          ") reports absent after applyHomebrewFormula"

        let postList = brewListVersions(brewExe, testFormula)
        doAssert postList.exitCode == 0,
          "post-apply: `brew list --formula --versions " &
          testFormula & "` failed (exit " & $postList.exitCode &
          "): " & postList.output.strip()
        let installedVersion = parseBrewVersionsLine(postList.output)
        doAssert installedVersion.len > 0 and
                 installedVersion != HomebrewAbsentVersion,
          "post-apply: out-of-band `brew list` did not produce a " &
          "version line: " & postList.output.strip()
        echo "  [observe] installed " & testFormula & " " &
          installedVersion

        # PATH symlink: Homebrew's Cellar+symlink shape guarantees
        # that a CLI formula's primary binary appears at
        # `<prefix>/bin/<name>`. This is what makes the formula
        # actually usable — the Cellar entry could exist without the
        # symlink (e.g. on a partial install), so we check both.
        let binPath = prefix / "bin" / testFormula
        doAssert fileExists(binPath),
          "post-apply: expected binary missing at " & binPath &
          " — `brew list` reports the formula present but the " &
          "Cellar+symlink shape Homebrew guarantees did not " &
          "materialize."

        # ---------------------------------------------------------------
        # 2. RE-APPLY: same operation. Should be a no-op from the
        #    drift-detection perspective; the observed version is
        #    stable across the no-op re-apply.
        # ---------------------------------------------------------------
        echo "  [re-apply] applyHomebrewFormula(" & testFormula & ")"
        let postBytes2 = applyHomebrewFormula(testFormula, "", @[])
        doAssert postBytes2 == postBytes,
          "re-apply: post-write bytes drifted; re-apply should be " &
          "a no-op from the drift-detection perspective. Before: " &
          $postBytes.len & " bytes; after: " & $postBytes2.len & " bytes"

        let obs2 = observeHomebrewFormula(testFormula, "")
        doAssert obs2.present
        doAssert obs2.digest == obs1.digest,
          "re-apply: observe digest drifted unexpectedly"

        # ---------------------------------------------------------------
        # 3. DESTROY: `destroyHomebrewFormula` uninstalls the formula.
        #    Post-destroy the formula must be absent both via the
        #    driver's observer AND via the out-of-band `brew list`
        #    witness, AND the `<prefix>/bin/<name>` symlink must be
        #    gone (Homebrew's `uninstall` removes the keg AND its
        #    forward-link).
        # ---------------------------------------------------------------
        echo "  [destroy] destroyHomebrewFormula(" & testFormula & ")"
        destroyHomebrewFormula(testFormula)

        let postDestroyObs = observeHomebrewFormula(testFormula, "")
        doAssert not postDestroyObs.present,
          "post-destroy: observeHomebrewFormula reports present " &
          "after destroyHomebrewFormula"

        let postDestroyList = brewListVersions(brewExe, testFormula)
        doAssert postDestroyList.exitCode != 0 or
                 parseBrewVersionsLine(postDestroyList.output) ==
                   HomebrewAbsentVersion,
          "post-destroy: `brew list --formula --versions " &
          testFormula & "` STILL reports a version after " &
          "destroyHomebrewFormula: " & postDestroyList.output.strip()

        doAssert not fileExists(binPath),
          "post-destroy: `<prefix>/bin/" & testFormula & "` STILL " &
          "exists at " & binPath & " after destroyHomebrewFormula " &
          "— `brew uninstall` was expected to remove the forward-" &
          "link symlink alongside the keg."

        echo "  [OK] pkg.homebrewFormula lifecycle: apply / re-apply " &
          "(no-op) / destroy round-trip on disposable formula " &
          testFormula & " (installed version " & installedVersion &
          "); out-of-band `brew list --formula --versions` + " &
          "`<prefix>/bin/<name>` symlink check verified install; " &
          "destroy uninstalls cleanly with no orphan keg or symlink."
