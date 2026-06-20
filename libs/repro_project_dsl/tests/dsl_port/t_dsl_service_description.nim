## DSL-port M9.C acceptance — service ``description "..."`` + ``type "..."``
## scalar setters.
##
## M9.C extends M5's minimal ``service:`` body (``executable`` + ``args``)
## with the systemd-unit metadata setters flagged by the M9 NDE-package
## discovery survey. This fixture pins the two simplest scalars
## (``description`` and ``type``) plus the executable + args round-trip,
## verifying:
##
##   * the M5 backward-compat surface (``executable`` + ``args``) still
##     populates ``DslServiceDef.executable`` / ``.args`` even when M9.C
##     setters are added alongside it;
##   * the new M9.C scalars (``description`` / ``serviceType``) land in
##     the registry verbatim with no kebab-translation;
##   * the empty-args defensive path survives the M9.C extension.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package svcDescPkg:
  executable myBin:
    build:
      discard
  service mySvc:
    executable myBin
    description "My service does something"
    `type` "simple"

package svcDescFullPkg:
  executable runner:
    build:
      discard
  service runnerSvc:
    executable runner
    description "Runner does real work"
    `type` "forking"
    args "--flag", "arg2"

suite "DSL-port M9.C — service description + type":
  test "service records description + type without args":
    let svcs = registeredServices("svcDescPkg")
    check svcs.len == 1
    let svc = svcs[0]
    check svc.serviceName == "mySvc"
    check svc.executable == "myBin"
    check svc.description == "My service does something"
    check svc.serviceType == "simple"
    check svc.args.len == 0

  test "service records description + type + args":
    let svcs = registeredServices("svcDescFullPkg")
    check svcs.len == 1
    let svc = svcs[0]
    check svc.serviceName == "runnerSvc"
    check svc.executable == "runner"
    check svc.description == "Runner does real work"
    check svc.serviceType == "forking"
    check svc.args.len == 2
    check svc.args[0] == "--flag"
    check svc.args[1] == "arg2"
    # M5 back-compat: the legacy ``executableRef`` field mirrors
    # ``executable`` so the three pinned M5 fixtures keep passing.
    check svc.executableRef == "runner"
