## ``playwright`` — Microsoft Playwright: the browser-automation library and
## the browser builds it drives.
##
## ## Linux and macOS — nixpkgs
##
## ``nixpkgs#playwright-test`` at the canonical pin. Unchanged by the Windows
## arms below.
##
## ## Windows — playwright-core 1.56.1 plus the browsers it pins
##
## Playwright is two things that must agree: the JavaScript library
## (``playwright-core``) and the browser builds of the exact revisions its
## ``browsers.json`` names. A library that finds a browser of another
## revision refuses to launch it, so the two are one realization here, not
## two packages a consumer could combine wrongly.
##
## * **The library** is the npm registry archive of ``playwright-core``
##   1.56.1, the version nixpkgs' ``playwright-driver`` carries on
##   ``nixos-25.11`` (``687f05a9``, checked 2026-11-12), so a project whose
##   Linux and macOS dev shells take Playwright from there drives the same
##   Playwright on Windows. It has no
##   ``dependencies`` (its ``package.json`` declares none: everything it
##   needs is bundled), so the one archive is the whole library.
##   ``stripComponents = 1`` drops npm's ``package/`` root, which makes the
##   prefix root the package directory itself: ``require(<prefix>)`` loads
##   it. Its sha256 was computed over the downloaded archive, whose sha512
##   matches the ``integrity`` the registry publishes for 1.56.1
##   (``sha512-hutraynyn31F…IXkgvmQ==``, checked 2026-11-12).
##
## * **The browsers** are Playwright's own Windows builds, from Playwright's
##   CDN, for the revisions 1.56.1's ``browsers.json`` names. They are the
##   closure manifest ``closures/playwright-core-1.56.1-windows.manifest``,
##   which realize unpacks into the prefix after the library. That file
##   lists each archive with its URL and sha256, and says how each one was
##   derived and checked.
##
## ### Layout: Playwright's own hermetic install
##
## The browsers land under ``<prefix>/.local-browsers/``. That is the
## directory playwright-core itself uses when ``PLAYWRIGHT_BROWSERS_PATH`` is
## ``0`` (``lib/server/registry/index.js``, ``registryDirectory``:
## ``path.join(__dirname, "..", "..", "..", ".local-browsers")``, the package
## root's ``.local-browsers``), the layout ``PLAYWRIGHT_BROWSERS_PATH=0 npx
## playwright install`` produces
## (https://playwright.dev/docs/browsers#hermetic-install). Inside it, each
## browser is ``<name with - as _>-<revision>`` (``readDescriptors``), and the
## executable is the path ``EXECUTABLE_PATHS[name].win`` gives:
##
##   ===============================================  ===========================
##   ``chromium-1194/chrome-win/chrome.exe``           ``chromium``
##   ``chromium_headless_shell-1194/chrome-win/``      ``chromium-headless-shell``
##   ``headless_shell.exe``
##   ``ffmpeg-1011/ffmpeg-win64.exe``                  ``ffmpeg``
##   ``winldd-1007/PrintDeps.exe``                     ``winldd``
##   ===============================================  ===========================
##
## Each archive already has the member layout below its directory
## (``chrome-win/…`` for both Chromium builds; ``ffmpeg-win64.exe`` and
## ``PrintDeps.exe`` at the top level), so every entry is unpacked with no
## strip. The set is the one ``playwright install chromium`` installs on
## Windows (``lib/cli/program.js``, ``checkBrowsersToInstall``): Chromium, its
## headless shell (what ``launch({ headless: true })`` starts, ``chromium.js``
## ``getExecutableName``), ffmpeg (video recording), and winldd, which
## Playwright runs on x64 Windows before the first launch to report missing
## system DLLs (``registry.validateHostRequirementsForExecutablesIfNeeded`` →
## ``dependencies.missingFileDependenciesWindows``) and without which the
## launch fails rather than skipping the check. Firefox and WebKit are not
## included.
##
## So a consumer needs two things and no knowledge of this layout: the
## prefix, which it loads playwright-core from (``require(<prefix>)``), and
## ``PLAYWRIGHT_BROWSERS_PATH=0`` in the environment it runs Playwright in.
##
## The arms declare no ``env`` for either. A tarball record's ``env`` is
## projected only into a home profile's activation, where it would be
## global: ``PLAYWRIGHT_BROWSERS_PATH=0`` there would send every other
## Playwright on the machine to its own package's ``.local-browsers`` instead
## of the shared browser cache. A project dev env publishes every realized
## package's prefix as ``REPRO_PREFIX_<PKG>``
## (``repro_cli_support.prefixEnvOpsForDevelop``), here
## ``REPRO_PREFIX_PLAYWRIGHT``, and the consumer sets
## ``PLAYWRIGHT_BROWSERS_PATH=0`` (and whatever variable it reads the
## library's location from) where it runs Playwright.
##
## ### Command
##
## ``executablePath`` is the package's CLI script, ``cli.js``, the ``bin``
## its ``package.json`` declares. ``launcher = "node"`` writes
## ``playwright-core`` and ``playwright-core.cmd`` beside it, each running
## ``node`` on it, under the name npm gives that ``bin``. It is
## playwright-core's CLI (``install``, ``codegen``, ``show-trace``, …), not
## ``@playwright/test``'s runner, which the nix arm's ``bin/playwright`` is;
## the name says which. ``node`` is resolved from the consumer's ``PATH``, so
## a consumer that runs the CLI declares ``node`` too (playwright-core 1.56.1
## needs ``node >= 18``).
##
## ### Windows on arm64
##
## Playwright publishes no arm64 Windows browser. Its platform detection maps
## every Windows host to ``win64`` whatever the architecture
## (``lib/server/utils/hostPlatform.js``), so ``playwright install`` on
## Windows arm64 installs these same x64 builds and Windows 11 runs them under
## its x64 emulation. The aarch64 arm therefore realizes the same archives.
## It skips winldd's check, as Playwright does on any non-x64 Windows
## (``registry._validateHostRequirements``: ``os.arch() === "x64"``), but
## carries winldd anyway so the two arms realize one tree. Its lock identity
## names the target, so the two arms stay distinguishable in a lock even
## though their bytes agree, as ``packages/swig.nim`` does for the same case.
##
## ### Refreshing
##
## A new Playwright version is a new library archive and new browser
## revisions together: take the version from the nixpkgs pin consumers lock,
## read its ``browsers.json`` for the revisions, rebuild the manifest from
## ``DOWNLOAD_PATHS[name]["win64"]`` in that version's registry code, and
## check each archive's members against ``EXECUTABLE_PATHS``.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const
  PlaywrightCoreVersion* = "1.56.1"
    ## The npm ``playwright-core`` version the Windows arms realize.
  PlaywrightCoreSha256* =
    "fa648e5442796d4160c68dcfc3914ed5224f147852264993e6376e29f0228238"
    ## sha256 of ``playwright-core-1.56.1.tgz`` (module doc).
  PlaywrightWindowsClosureManifest* =
    "closures/playwright-core-1.56.1-windows.manifest"
    ## The browser builds, relative to this module's directory (module doc).

package playwright:
  provisioning:
    nixPackage "nixpkgs#playwright-test", executablePath = "bin/playwright",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash,
      packageId = "playwright"
    # Windows x86_64: playwright-core from the npm registry, with the
    # Chromium, headless-shell, ffmpeg and winldd builds its browsers.json
    # pins unpacked into `.local-browsers/` (module doc, "Layout").
    tarball url = "https://registry.npmjs.org/playwright-core/-/playwright-core-" &
        PlaywrightCoreVersion & ".tgz",
      sha256 = PlaywrightCoreSha256,
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "cli.js",
      executableAlias = "playwright-core",
      launcher = "node",
      closureManifest = PlaywrightWindowsClosureManifest,
      version = PlaywrightCoreVersion,
      packageId = "playwright-core@" & PlaywrightCoreVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:playwright-core@" & PlaywrightCoreVersion &
        ":windows-x86_64:sha256:" & PlaywrightCoreSha256
    # Windows aarch64: the SAME archives. Playwright ships no arm64 Windows
    # browser and installs the x64 builds there itself, which Windows 11 runs
    # under x64 emulation (module doc, "Windows on arm64").
    tarball url = "https://registry.npmjs.org/playwright-core/-/playwright-core-" &
        PlaywrightCoreVersion & ".tgz",
      sha256 = PlaywrightCoreSha256,
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "cli.js",
      executableAlias = "playwright-core",
      launcher = "node",
      closureManifest = PlaywrightWindowsClosureManifest,
      version = PlaywrightCoreVersion,
      packageId = "playwright-core@" & PlaywrightCoreVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:playwright-core@" & PlaywrightCoreVersion &
        ":windows-aarch64:sha256:" & PlaywrightCoreSha256
