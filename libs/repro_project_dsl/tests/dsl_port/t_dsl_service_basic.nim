## DSL-port M5 acceptance — basic ``service:`` block registration.
##
## Pins the contract for M5's ``service`` block lowering. The M5 emitter
## walks the partitioned section list (via the M3 ``classifyPackageSections``
## seam), filters for the new ``soM5Service`` ownership tag, extracts the
## (a) service name from the section call head (ident or string-form),
## (b) the referenced ``executable`` ident from the body's
## ``executable <ident>`` setter, (c) the positional ``args``, and emits
## one ``registerService(...)`` runtime call per recognised block.
##
## The legacy ``parsePackageDef`` walker does NOT process ``service:``
## entries at all (no arm exists for it in ``macros_a.nim``), so M5
## owns the section exclusively — symmetric with M3's ``files:``
## treatment.

import std/[unittest]

import repro_project_dsl

package svcPkg:
  executable myDaemon:
    build:
      output("bin/myDaemon")

  service myService:
    executable myDaemon
    args "--verbose"

package svcPkg2:
  executable d:
    build:
      discard
  service mySvc:
    executable d

suite "DSL-port M5 — service: block basic":
  test "service registers with name":
    let svcs = registeredServices("svcPkg")
    check svcs.len == 1
    check svcs[0].serviceName == "myService"
    check svcs[0].executableRef == "myDaemon"
    check svcs[0].args.len == 1
    check svcs[0].args[0] == "--verbose"

  test "service registered against package":
    let svcs = registeredServices("svcPkg2")
    check svcs.len == 1
    check svcs[0].serviceName == "mySvc"
