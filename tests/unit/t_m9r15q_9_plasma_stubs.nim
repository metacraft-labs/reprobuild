## DSL-port M9.R.15q.9.2 — Plasma / KF6 stdlib stub registration test.
##
## Pins the M9.R.15q.9.2 widening: plasma-workspace's CMakeLists.txt
## ``find_package`` probes pull in a long tail of KF6 + Plasma + Qt6
## modules beyond what kwin / sddm already needed. Each new stub
## registers its canonical package name + a Nix provisioning channel
## so the from-source resolver can route ``buildDeps: "kparts >=6.0"``
## (etc.) through the stdlib without short-failing with:
##
##   tool-resolution failed: --tool-provisioning=from-source requested
##   for "kparts" (package "kparts") but no sibling recipe ... and no
##   stdlib provisioning channel ... declared.
##
## The fifteen stubs cover:
##
##   * qcoro6                 — C++20 coroutines wrapper for Qt
##   * kparts                 — KParts document-component framework
##   * krunner                — KRunner quick-launcher framework
##   * knotifyconfig          — KNotifyConfig UI helper
##   * kwallet                — KWallet secret-storage framework
##   * kprison                — Prison barcode-rendering library
##   * ktextwidgets           — KTextWidgets rich-text edit shell
##   * ksysguard              — libksysguard system-load library
##   * layer-shell-qt         — LayerShellQt Wayland surface binding
##   * phonon4qt6             — Phonon4Qt6 multimedia dispatcher
##   * plasma5support         — Plasma5Support legacy-API bridge
##   * plasma-activities-stats — KActivities usage-database reader
##   * kscreen                — libkscreen multi-monitor config
##   * breeze                 — Breeze default Plasma style + theme
##   * qt6-positioning        — QtPositioning core + Quick libraries
##
## Plus a re-verification that the THREE stubs lifted in earlier
## M9.R.15q waves are still routed through the aggregator:
##
##   * kpipewire              — M9.R.15q.4.5 wave
##   * kglobalacceld          — M9.R.15q.4.5 wave
##   * kscreenlocker          — M9.R.15q.4.5 wave

import std/[tables, unittest]

import repro_project_dsl
# Pull the KF6 / Qt6 sub-module aggregator so the M9.R.15q.9.2 stubs
# register at module-init time and ``registeredPackages()`` can find
# them.
import repro_dsl_stdlib/packages/kf6_qt6_modules

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

const CanonicalNixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"

const NewStubNames = @[
  "qcoro6",
  "kparts",
  "krunner",
  "knotifyconfig",
  "kwallet",
  "kprison",
  "ktextwidgets",
  "ksysguard",
  "layer-shell-qt",
  "phonon4qt6",
  "plasma5support",
  "plasma-activities-stats",
  "kscreen",
  "breeze",
  "qt6-positioning",
]

const PriorWaveStubNames = @[
  "kpipewire",
  "kglobalacceld",
  "kscreenlocker",
]

const StubSelectors = {
  "qcoro6":                  "nixpkgs#qcoro",
  "kparts":                  "nixpkgs#kdePackages.kparts",
  "krunner":                 "nixpkgs#kdePackages.krunner",
  "knotifyconfig":           "nixpkgs#kdePackages.knotifyconfig",
  "kwallet":                 "nixpkgs#kdePackages.kwallet",
  "kprison":                 "nixpkgs#kdePackages.prison",
  "ktextwidgets":            "nixpkgs#kdePackages.ktextwidgets",
  "ksysguard":               "nixpkgs#kdePackages.libksysguard",
  "layer-shell-qt":          "nixpkgs#kdePackages.layer-shell-qt",
  "phonon4qt6":              "nixpkgs#kdePackages.phonon",
  "plasma5support":          "nixpkgs#kdePackages.plasma5support",
  "plasma-activities-stats": "nixpkgs#kdePackages.plasma-activities-stats",
  "kscreen":                 "nixpkgs#kdePackages.libkscreen",
  "breeze":                  "nixpkgs#kdePackages.breeze",
  "qt6-positioning":         "nixpkgs#qt6.qtpositioning",
}.toTable

suite "DSL-port M9.R.15q.9.2 — Plasma / KF6 stdlib stubs":

  test "all fifteen NEW M9.R.15q.9.2 stubs register as packages":
    for name in NewStubNames:
      let pkg = findPackage(name)
      check pkg.packageName == name

  test "each NEW stub declares at least one nix provisioning channel":
    for name in NewStubNames:
      let pkg = findPackage(name)
      check pkg.nixProvisioning.len >= 1

  test "each NEW stub points at the expected nix selector":
    for name in NewStubNames:
      let pkg = findPackage(name)
      let expected = StubSelectors[name]
      var seenSelector = false
      for nix in pkg.nixProvisioning:
        if nix.selector == expected:
          seenSelector = true
      check seenSelector

  test "each NEW stub pins the canonical nixpkgs rev":
    for name in NewStubNames:
      let pkg = findPackage(name)
      for nix in pkg.nixProvisioning:
        check nix.nixpkgsRev == CanonicalNixpkgsRev

  test "earlier M9.R.15q wave stubs still register through the aggregator":
    for name in PriorWaveStubNames:
      let pkg = findPackage(name)
      check pkg.packageName == name
      check pkg.nixProvisioning.len >= 1
