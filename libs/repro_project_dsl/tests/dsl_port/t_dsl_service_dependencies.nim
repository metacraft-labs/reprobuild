## DSL-port M9.C acceptance — service dependency + run-as + env setters.
##
## Covers the rest of the M9.C systemd-unit metadata surface flagged by
## the NDE-package discovery survey:
##
##   * ``wantedBy`` / ``wants`` / ``requires`` / ``before`` / ``after`` —
##     repeating setters; appended in declaration order per package.
##   * ``env("KEY", "VALUE")`` — call form. Two string-literal args per
##     entry; appended in declaration order. The call form was picked
##     over ``env "KEY"="VALUE"`` because the latter parses as
##     ``Command(Ident "env", Asgn(StrLit, StrLit))`` which is noisy at
##     the macro layer; the call form falls out as a clean ``nnkCall``
##     and matches how M4 already lowers ``output("path")``.
##   * ``restart`` / ``user`` / ``group`` — last-wins scalars.
##   * ``execStart "..."`` — full command-string alternative to the
##     ``executable`` + ``args`` lowering; lets NDE recipes pin a literal
##     command (``/usr/bin/dbus-broker-launch --scope system --audit``)
##     without going through an artifact ref.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package svcDepsPkg:
  executable dbusBroker:
    build:
      discard
  service systemBus:
    executable dbusBroker
    description "D-Bus system bus"
    `type` "dbus"
    wantedBy "multi-user.target"
    wantedBy "graphical.target"
    wants "dbus.socket"
    requires "messagebus.target"
    before "basic.target"
    after "syslog.target"
    after "network.target"
    env("DBUS_DEBUG", "1")
    env("LANG", "C")
    restart "on-failure"
    user "messagebus"
    group "messagebus"

package svcExecStartPkg:
  service brokerLauncher:
    description "D-Bus broker launcher"
    `type` "dbus"
    execStart "/usr/bin/dbus-broker-launch --scope system --audit"
    wantedBy "multi-user.target"

suite "DSL-port M9.C — service dependencies + env + run-as":
  test "service records full dependency + env + run-as surface":
    let svcs = registeredServices("svcDepsPkg")
    check svcs.len == 1
    let svc = svcs[0]
    # Identity + executable + description + type.
    check svc.serviceName == "systemBus"
    check svc.executable == "dbusBroker"
    check svc.description == "D-Bus system bus"
    check svc.serviceType == "dbus"
    # Repeating dependency setters preserve declaration order.
    check svc.wantedBy == @["multi-user.target", "graphical.target"]
    check svc.wants == @["dbus.socket"]
    check svc.requires == @["messagebus.target"]
    check svc.before == @["basic.target"]
    check svc.after == @["syslog.target", "network.target"]
    # Env pairs (call-form): order + tuple shape.
    check svc.env.len == 2
    check svc.env[0].key == "DBUS_DEBUG"
    check svc.env[0].value == "1"
    check svc.env[1].key == "LANG"
    check svc.env[1].value == "C"
    # Restart + run-as scalars.
    check svc.restart == "on-failure"
    check svc.user == "messagebus"
    check svc.group == "messagebus"
    # execStart unused here — pure ``executable`` pathway leaves it
    # at the empty-string ground state.
    check svc.execStart == ""

  test "service records execStart alternative without executable":
    let svcs = registeredServices("svcExecStartPkg")
    check svcs.len == 1
    let svc = svcs[0]
    check svc.serviceName == "brokerLauncher"
    # No ``executable <ident>`` setter → both the legacy
    # ``executableRef`` and the new ``executable`` alias stay empty.
    check svc.executable == ""
    check svc.executableRef == ""
    check svc.execStart ==
      "/usr/bin/dbus-broker-launch --scope system --audit"
    check svc.description == "D-Bus broker launcher"
    check svc.serviceType == "dbus"
    check svc.wantedBy == @["multi-user.target"]
    # Defensive empty-args guarantee survives the execStart pathway.
    check svc.args.len == 0
