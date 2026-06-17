## DSL-port M9.I acceptance — ``mesonOptions:`` block registry.
##
## Pins the M9.I ``mesonOptions:`` directive contract. Real packages
## like ``dbus-broker`` declare per-package flags passed to
## ``meson setup`` via this block; the body is a sequence of string
## literals (one per line, no setters). The block is repeatable inside a
## package body — successive blocks APPEND to the registered seq.
##
## Coverage:
##
##   * Test 1 — basic meson register: one block declaring two flags.
##     The registry round-trips the EXACT sequence (order-preserving) +
##     other channels stay empty.
##
##   * Test 2 — channel isolation: declaring ``mesonOptions:`` MUST NOT
##     leak into the ``cmake`` / ``configure`` / ``make`` / ``ninja``
##     channels (independent per-channel seqs).

import std/[unittest]

import repro_project_dsl

package mesonPkg:
  mesonOptions:
    "-Daudit=false"
    "-Dlauncher=true"

suite "DSL-port M9.I — mesonOptions: block registry":

  test "mesonOptions registers ordered flag sequence":
    let flags = registeredBuildFlags("mesonPkg", "", "meson")
    # Exact-sequence round trip (order-preserving — flag order is
    # load-bearing for some build systems).
    check flags == @["-Daudit=false", "-Dlauncher=true"]
    # Length sanity (degenerate-but-cheap check that registration
    # happened and the seq is not empty).
    check flags.len == 2
    # First/last spot-checks so a regression that flips order (e.g. a
    # set-backed registry replacing the seq) shows up loudly.
    check flags[0] == "-Daudit=false"
    check flags[1] == "-Dlauncher=true"

  test "mesonOptions does not leak into other channels":
    # The four sibling channels are independent registries; declaring
    # ``mesonOptions:`` must not populate any of them for the same
    # package. (A bug here would short-circuit the per-channel
    # convention-layer consumer in M9.L.)
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("mesonPkg", "", "cmake") == emptyStrSeq
    check registeredBuildFlags("mesonPkg", "", "configure") == emptyStrSeq
    check registeredBuildFlags("mesonPkg", "", "make") == emptyStrSeq
    check registeredBuildFlags("mesonPkg", "", "ninja") == emptyStrSeq
