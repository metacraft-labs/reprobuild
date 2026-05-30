## Reprobuild Homebrew adapter (M83 step 9).
##
## Two macOS package backends parallel to the M55/M70 Scoop adapter
## (Windows) and the Nix profile adapter (Linux/macOS):
##
##   * `pkg.homebrewFormula` — Homebrew CLI formulae
##     (`brew install <name>`). Shipped in M83 step 9 Driver A.
##   * `pkg.homebrewCask`    — Homebrew Cask GUI/binary apps
##     (`brew install --cask <name>`). Shipped in M83 step 9
##     Driver B.
##
## Both backends shell out to the same `brew` CLI; the shared
## helpers (binary discovery, prefix lookup, argv composition, name
## validation, version-line parsing) live in `./repro_homebrew_adapter/
## common.nim`.
##
## Both backends are HOME-SCOPE — Homebrew installs under the
## user-writable Homebrew prefix (`/usr/local` on Intel, `/opt/homebrew`
## on Apple Silicon) and runs unelevated. The drivers plug into the
## same home-apply package-realization machinery
## (`libs/repro_home_apply/`) that materializes `windows.startup`,
## `linux.dconfKey`, etc.
##
## The drivers raise `ENotImplementedPlatform("pkg.homebrew*",
## "macosx")` off-macOS — fail-closed, NOT a silent no-op.

import ./repro_homebrew_adapter/common
import ./repro_homebrew_adapter/formula
import ./repro_homebrew_adapter/cask

export common
export formula
export cask
