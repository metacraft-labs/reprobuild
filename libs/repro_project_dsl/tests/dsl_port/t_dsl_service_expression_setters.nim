## Service setters take an EXPRESSION, not only a string literal.
##
## `m5ServiceStringLitArg` used to require `nnkStrLit` / `nnkRStrLit` /
## `nnkTripleStrLit` and return `nil` for anything else. The caller only
## assigned the field when the result was non-nil, so a `const` or a helper call
## was **silently dropped** — the setter compiled, produced no diagnostic, and
## left the field at its empty-string ground state. That is the same silent
## class of failure as a term-rewriting template without an export marker: it
## looks like it worked.
##
## The macro never needed the value. The argument is spliced verbatim into the
## generated call (`quote do: setActiveServiceDescription(`lit`)`), so the Nim
## compiler type-checks and evaluates it. Relaxing the gate to accept any
## expression is transform-don't-evaluate applied to this declaration: the macro
## relocates the node, the compiler resolves it.
##
## A consequence worth stating: a non-string expression now fails at the spliced
## call site with an ordinary type mismatch rather than vanishing. Erroring is
## the improvement.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types

# The reusable-vocabulary shape this exists to enable — named once, used at
# each declaration, instead of repeating bare strings.
type ServiceFlavour = enum
  sfSystem
  sfSession

func unitType(flavour: ServiceFlavour): string =
  case flavour
  of sfSystem: "notify"
  of sfSession: "simple"

const SharedDescription = "Shared description from a const"

package svcExprPkg:
  executable exprBin:
    build:
      discard
  service exprSvc:
    executable exprBin
    # const — previously dropped without a word
    description SharedDescription
    # func call — the reusable-vocabulary case, also previously dropped
    `type` unitType(sfSystem)

# `m5ServiceStringLitArg` is shared by ELEVEN setters, so relaxing it should
# have relaxed all eleven. "Shared helper, therefore all work" is an inference,
# not a result — this exercises each one rather than trusting the reasoning.
const
  Target = "multi-user.target"
  UnitName = "network-online.target"
  SvcUser = "repro"

func restartPolicy(always: bool): string =
  if always: "always" else: "on-failure"

package svcExprAllPkg:
  executable allBin:
    build:
      discard
  service allSvc:
    executable allBin
    description SharedDescription
    `type` unitType(sfSystem)
    execStart "/usr/bin/" & "true"
    wantedBy Target
    wants UnitName
    requires UnitName
    before Target
    after UnitName
    restart restartPolicy(true)
    user SvcUser
    group SvcUser

package svcExprMixedPkg:
  executable mixedBin:
    build:
      discard
  service mixedSvc:
    executable mixedBin
    # a literal and an expression side by side must both land
    description "Literal still works"
    `type` unitType(sfSession)

suite "service setters accept expressions, not only literals":
  test "a const reaches the registry":
    let svcs = registeredServices("svcExprPkg")
    check svcs.len == 1
    check svcs[0].description == "Shared description from a const"

  test "a func call reaches the registry — the reusable-vocabulary case":
    let svcs = registeredServices("svcExprPkg")
    check svcs[0].serviceType == "notify"

  test "all eleven shared setters accept an expression":
    let svcs = registeredServices("svcExprAllPkg")
    check svcs.len == 1
    let s = svcs[0]
    check s.description == "Shared description from a const"
    check s.serviceType == "notify"
    check s.execStart == "/usr/bin/true"
    check s.wantedBy == @["multi-user.target"]
    check s.wants == @["network-online.target"]
    check s.requires == @["network-online.target"]
    check s.before == @["multi-user.target"]
    check s.after == @["network-online.target"]
    check s.restart == "always"
    check s.user == "repro"
    check s.group == "repro"

  test "literals are unaffected alongside expressions":
    let svcs = registeredServices("svcExprMixedPkg")
    check svcs.len == 1
    check svcs[0].description == "Literal still works"
    check svcs[0].serviceType == "simple"
