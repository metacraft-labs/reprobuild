## DSL-port M5 acceptance — service ``args "...", "..."`` setter.
##
## Pins the contract for M5's ``args`` body-setter: a variadic string
## list whose elements land in ``DslServiceDef.args`` in declaration
## order. Mirrors v8's ``serviceArgs(varargs[string, $])`` proc — but
## M5 currently only accepts already-string literals (M6+ may widen to
## variant references / typed paths once those surfaces land).
##
## A second fixture pins the empty-args path: a service without any
## ``args`` setter produces ``DslServiceDef.args.len == 0`` rather than
## raising. This is the "defensive empty-args" guarantee the M4 reviewer
## risk #5 calls out — symmetric with M4's zero-frame ``currentBuild
## Context()`` convention.

import std/[unittest]

import repro_project_dsl

package argsPkg:
  executable runner:
    build:
      discard
  service argService:
    executable runner
    args "--host", "localhost", "--port", "8080", "--verbose"

package noArgsPkg:
  executable e:
    build:
      discard
  service silentService:
    executable e

suite "DSL-port M5 — service args":
  test "service args recorded in order":
    let svcs = registeredServices("argsPkg")
    check svcs.len == 1
    let s = svcs[0]
    check s.args.len == 5
    check s.args[0] == "--host"
    check s.args[1] == "localhost"
    check s.args[2] == "--port"
    check s.args[3] == "8080"
    check s.args[4] == "--verbose"

  test "service with no args produces empty seq":
    let svcs = registeredServices("noArgsPkg")
    check svcs.len == 1
    check svcs[0].args.len == 0
