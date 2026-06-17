## DSL-port M9.I acceptance — all five flag-injection channels.
##
## Pins the M9.I block taxonomy: ``mesonOptions:`` / ``cmakeFlags:`` /
## ``configureFlags:`` / ``makeFlags:`` / ``ninjaFlags:`` registered on
## a single package and the registry partitions flags into independent
## per-channel seqs (no cross-channel bleeding).
##
## The ``makeFlags:`` case carries two flags so an order-preserving
## sequence equality assertion catches any reordering bug — ``make``'s
## left-to-right variable-override precedence means a regression that
## swaps ``ARCH=x86_64`` with ``V=1`` would silently change build
## behaviour.
##
## Coverage:
##
##   * Test 1 — single-package five-channel cross product: each channel
##     returns the exact registered seq, in the declared order.

import std/[unittest]

import repro_project_dsl

package allFlagsPkg:
  mesonOptions:
    "-Dx=1"
  cmakeFlags:
    "-DY=2"
  configureFlags:
    "--with-z"
  makeFlags:
    "ARCH=x86_64"
    "V=1"
  ninjaFlags:
    "-j4"

suite "DSL-port M9.I — five-channel cross product":

  test "every channel registers its declared flag sequence":
    # mesonOptions channel — one flag declared, round-trip exact.
    let meson = registeredBuildFlags("allFlagsPkg", "", "meson")
    check meson == @["-Dx=1"]
    check meson.len == 1
    # cmakeFlags channel — disjoint from meson.
    let cmake = registeredBuildFlags("allFlagsPkg", "", "cmake")
    check cmake == @["-DY=2"]
    check cmake.len == 1
    # configureFlags channel — autotools-style ``--with-*`` shape.
    let configure = registeredBuildFlags("allFlagsPkg", "", "configure")
    check configure == @["--with-z"]
    check configure.len == 1
    # makeFlags channel — TWO flags, exact-order sequence equality so
    # any reordering regression surfaces. ``ARCH=x86_64`` must come
    # before ``V=1`` (declaration order) because ``make``'s variable
    # precedence is left-to-right.
    let makeF = registeredBuildFlags("allFlagsPkg", "", "make")
    check makeF == @["ARCH=x86_64", "V=1"]
    check makeF.len == 2
    check makeF[0] == "ARCH=x86_64"
    check makeF[1] == "V=1"
    # ninjaFlags channel — one flag declared.
    let ninja = registeredBuildFlags("allFlagsPkg", "", "ninja")
    check ninja == @["-j4"]
    check ninja.len == 1
