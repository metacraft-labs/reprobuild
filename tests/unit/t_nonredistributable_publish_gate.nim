## The license-policy gate on cache publication.
##
## A `nonRedistributable` payload — a vendored coding agent whose licence
## lets this machine fetch and realize it but not re-serve it — must never be
## uploaded to a shared binary cache. `publishToolPrefix` enforces that by
## consulting `barredFromCachePublication` BEFORE it looks for publish
## credentials, so the refusal is a property of the package rather than an
## accident of whether the machine happens to have credentials configured.
## These cases pin that predicate: the property under test is exactly the one
## `test_nonredistributable_agent_is_not_published_to_cache` names — a
## restricted payload stays out of the cache — reduced to the pure decision
## so it can be checked without a keypair, an endpoint, or a network.

import std/unittest

import repro_tool_profiles

suite "the nonRedistributable cache-publication gate":

  test "a nonRedistributable plan is barred from cache publication":
    var plan: TarballAcquisitionPlan
    plan.declaredNonRedistributable = true
    check barredFromCachePublication(plan)

  test "an ordinary (redistributable) plan is not barred":
    var plan: TarballAcquisitionPlan
    # declaredNonRedistributable defaults to false — the redistributable case.
    check not barredFromCachePublication(plan)

  test "the bar is a property of the plan, independent of any other field":
    # A plan can carry credentials-shaped or endpoint-shaped data elsewhere in
    # the pipeline; the gate reads ONLY the license flag, which is what lets
    # `publishToolPrefix` check it before — and independently of — credentials.
    var plan: TarballAcquisitionPlan
    plan.packageSelector = "claude-code"
    plan.packageId = "claude-code@2.1.272"
    plan.url = "https://example.invalid/claude"
    plan.declaredNonRedistributable = true
    check barredFromCachePublication(plan)
    plan.declaredNonRedistributable = false
    check not barredFromCachePublication(plan)
