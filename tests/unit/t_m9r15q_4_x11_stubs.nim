## DSL-port M9.R.15q.4.1 — X11 stdlib stub registration test.
##
## Pins the M9.R.15q.4.1 widening: plasma-framework's KX11Extras
## dependency requires kwindowsystem to be built with
## ``KWINDOWSYSTEM_X11=ON`` which in turn requires a from-source /
## stdlib-provisioning surface for the canonical X11 client
## libraries.  Without these stubs the resolver short-fails with:
##
##   tool-resolution failed: --tool-provisioning=from-source requested
##   for "libx11" (package "libx11") but no sibling recipe ... and no
##   stdlib provisioning channel ... declared.
##
## The thirteen stubs cover:
##   * libx11           — canonical Xlib client library
##   * libxcb           — modern XCB client library
##   * xcb-util-keysyms — keysym helpers
##   * xcb-util-wm      — ICCCM + EWMH helpers
##   * xcb-util-renderutil — XRender helpers
##   * xcb-util-image   — XImage helpers
##   * xcb-util-cursor  — XDG cursor-theme loader
##   * xcb-util         — umbrella convenience routines
##   * libxext          — standard X11 extensions
##   * libxfixes        — X Fixes extension
##   * libxrender       — X Render extension
##   * xorgproto        — X protocol headers (X11/X.h)
##   * libxau           — X authentication (libxcb's Requires.private)
##
## Each stub points at a ``nixpkgs#xorg.*^*`` (or ``nixpkgs#xorg.libX*^*``)
## selector with the ``^*`` multi-output suffix so the M9.R.14f.10
## resolver walks every realized store output for the .pc + headers
## (dev output) + the .so (out output).

import std/[tables, unittest]

import repro_project_dsl
# Pull the system-tools aggregator so the M9.R.15q.4.1 stubs register
# at module-init time and ``registeredPackages()`` can find them.
import repro_dsl_stdlib/packages/system_tools

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

const CanonicalNixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"

const StubNames = @[
  "libx11",
  "libxcb",
  "xcb-util-keysyms",
  "xcb-util-wm",
  "xcb-util-renderutil",
  "xcb-util-image",
  "xcb-util-cursor",
  "xcb-util",
  "libxext",
  "libxfixes",
  "libxrender",
  # M9.R.15q.4.3 — xorgproto carries X11/X.h (CMake's FindX11 probe).
  "xorgproto",
  # M9.R.15q.4.3 — libxau is xcb.pc's Requires.private dep; without
  # it pkg-config probes through xcb fail.
  "libxau",
]

const StubSelectors = {
  "libx11":              "nixpkgs#xorg.libX11^*",
  "libxcb":              "nixpkgs#xorg.libxcb^*",
  "xcb-util-keysyms":    "nixpkgs#xorg.xcbutilkeysyms^*",
  "xcb-util-wm":         "nixpkgs#xorg.xcbutilwm^*",
  "xcb-util-renderutil": "nixpkgs#xorg.xcbutilrenderutil^*",
  "xcb-util-image":      "nixpkgs#xorg.xcbutilimage^*",
  "xcb-util-cursor":     "nixpkgs#xorg.xcbutilcursor^*",
  "xcb-util":            "nixpkgs#xorg.xcbutil^*",
  "libxext":             "nixpkgs#xorg.libXext^*",
  "libxfixes":           "nixpkgs#xorg.libXfixes^*",
  "libxrender":          "nixpkgs#xorg.libXrender^*",
  "xorgproto":           "nixpkgs#xorg.xorgproto",
  "libxau":              "nixpkgs#xorg.libXau^*",
}.toTable

suite "DSL-port M9.R.15q.4.1 — X11 stdlib stubs":

  test "all thirteen X11 stubs register as packages":
    for name in StubNames:
      let pkg = findPackage(name)
      check pkg.packageName == name

  test "each X11 stub declares at least one nix provisioning channel":
    for name in StubNames:
      let pkg = findPackage(name)
      check pkg.nixProvisioning.len >= 1

  test "each X11 stub points at the expected nix selector":
    for name in StubNames:
      let pkg = findPackage(name)
      let expected = StubSelectors[name]
      var seenSelector = false
      for nix in pkg.nixProvisioning:
        if nix.selector == expected:
          seenSelector = true
      check seenSelector

  test "each X11 stub pins the canonical nixpkgs rev":
    for name in StubNames:
      let pkg = findPackage(name)
      for nix in pkg.nixProvisioning:
        check nix.nixpkgsRev == CanonicalNixpkgsRev
