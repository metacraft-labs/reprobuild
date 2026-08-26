## Guards on the HAZARDOUS ``trustedDeclaredInputsPolicy``.
##
## The policy disables monitoring and result processing for an edge and trusts
## whatever the author declared. Unrestricted forms of that idea have been
## added to this codebase and removed three times as soundness holes; the
## narrow form is owner-authorized (2026-08-21) on the condition that it stay
## discouraged and impossible to reach by accident.
##
## These cases pin the "impossible by accident" half: the policy cannot be
## constructed without an explicit input list AND a written justification. If
## either guard is relaxed, the policy silently becomes a general-purpose
## "skip dependency tracking" switch, which is precisely what was banned.

import std/unittest
import repro_project_dsl

suite "trustedDeclaredInputsPolicy guards":

  test "a well-formed call yields the trusted kind":
    let p = trustedDeclaredInputsPolicy(
      @["build/test-bin/t_example"], "cannot be monitored: self-interposes")
    check p.kind == bdpTrustedDeclaredInputs
    check p.trustedInputs == @["build/test-bin/t_example"]
    check p.trustedReason.len > 0

  test "an empty input list is refused":
    # Would disable dependency tracking entirely — the banned shape.
    expect ValueError:
      discard trustedDeclaredInputsPolicy(@[], "some reason")

  test "a list of only empty paths is refused":
    expect ValueError:
      discard trustedDeclaredInputsPolicy(@["", ""], "some reason")

  test "a missing reason is refused":
    # The reason is surfaced in the build report; without it the trust is
    # invisible outside the recipe.
    expect ValueError:
      discard trustedDeclaredInputsPolicy(@["a"], "")

  test "a whitespace-only reason is refused":
    expect ValueError:
      discard trustedDeclaredInputsPolicy(@["a"], "   \t\n ")

  test "duplicate declared paths collapse":
    let p = trustedDeclaredInputsPolicy(@["a", "a", "b"], "r")
    check p.trustedInputs == @["a", "b"]
