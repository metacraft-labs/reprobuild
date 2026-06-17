## DSL-port M1 acceptance — Nim-statement preservation inside `package`.
##
## v8's `transformPackageBody` proc preserves arbitrary Nim statements
## (let, var, for, proc, template, when, if, echo, discard, plain proc
## call) that appear at the top level of a `package <name>:` body.
## Production's "add-alongside" port (`preservedTopLevelNodes` in
## `cross_project.nim`) collects every non-section statement and emits
## it at module top level alongside the macro's generated code.
##
## This file pins the M1 contract for the non-trivial Nim shapes:
##
##   * a top-level `let` binding to an array literal;
##   * a top-level `for` loop over that array;
##   * a top-level `proc` definition;
##   * a top-level call to that proc.
##
## All four must survive macro expansion. The compile-as-assertion
## pattern from `t_multi_package_macro.nim` applies: if any of these
## statements were silently dropped or routed into a build proc that
## never runs, either (a) the module-level effect (the `tracker`
## sequence being mutated) would never happen and the `suite` would
## flag it, or (b) compilation itself would fail with "undeclared
## identifier" on the helper proc.
##
## No special compile defines required — this test exercises macro
## expansion + the runtime registry, neither of which needs
## `reproProviderMode` or any other gate.

import std/[strutils, unittest]

import repro_project_dsl

# Module-level tracker — the `for` loop inside `loopPkg` writes into
# this so the suite can prove the loop executed at module init time.
var loopTrackerRuntime: seq[string] = @[]

package loopPkg:
  # Top-level `let` binding — the v8 contract preserves this verbatim.
  let items = ["a", "b", "c"]
  # Top-level `for` loop — must run when the module is initialised so
  # `loopTrackerRuntime` is fully populated by the time `suite` runs.
  for item in items:
    loopTrackerRuntime.add(item)

package helperPkg:
  # Top-level `let` binding bound to a string literal.
  let greeting = "hello"
  # Top-level helper `proc` — the v8 contract preserves this verbatim
  # so it is callable from anywhere in the surrounding module.
  proc shout(s: string): string = s.toUpperAscii()
  # Top-level call to the helper. Result is `discard`ed because there
  # is no useful side-effect surface inside a package body, but the
  # call must compile — i.e. `shout` must be in scope at the call site.
  discard shout(greeting)

suite "DSL-port M1 — composition for-loop preservation":

  test "loopPkg's top-level `for` loop ran at module init time":
    # The loop body appends each item to `loopTrackerRuntime`. If the
    # `package` macro dropped the loop, the tracker would be empty.
    check loopTrackerRuntime == @["a", "b", "c"]

  test "loopPkg registers as a package":
    let packages = registeredPackages()
    var found = false
    for p in packages:
      if p.packageName == "loopPkg":
        found = true
        break
    check found

  test "loopPkg emits the standard <selector>* const":
    check declared(loop_pkg)

  test "helperPkg registers as a package":
    let packages = registeredPackages()
    var found = false
    for p in packages:
      if p.packageName == "helperPkg":
        found = true
        break
    check found

  test "helperPkg's helper proc is reachable at module scope":
    # If `proc shout` was dropped by the macro, this call would fail
    # to compile. Compiling at all is one assertion; the value check
    # is the second.
    check shout("hello") == "HELLO"

  test "helperPkg emits the standard <selector>* const":
    check declared(helper_pkg)
