## `ScopedEnv` restores each variable when its last holder goes away, in
## whatever order its scopes end: a scope that ends under a live one leaves
## the live one's value in place.
import std/[os, unittest]
import repro_test_support/scoped_env

const Name = "REPRO_SCOPED_ENV_TEST_VARIABLE"

suite "ScopedEnv":
  setup:
    delEnv(Name)

  test "nested scopes restore in reverse, an unset variable stays unset":
    block:
      let outer {.used.} = scopedEnv([(Name, "outer")])
      block:
        let inner {.used.} = scopedEnv([(Name, "inner")])
        check getEnv(Name) == "inner"
      check getEnv(Name) == "outer"
    check not existsEnv(Name)

  test "a set variable gets its value back, through a copy and an exception":
    putEnv(Name, "before")
    proc failing() =
      let env = scopedEnv([(Name, "during")])
      let copy {.used.} = env
      check getEnv(Name) == "during"
      raise newException(ValueError, "leaving")
    expect ValueError:
      failing()
    check getEnv(Name) == "before"

  test "a scope that ends under a live one does not restore over it":
    putEnv(Name, "before")
    var first = scopedEnv([(Name, "first")])
    var second = scopedEnv([(Name, "second")])
    # The first scope ends while the second still holds the variable: the
    # assignment of a new fixture over a live one ends scopes in this order.
    first = nil
    check getEnv(Name) == "second"
    second = nil
    check getEnv(Name) == "before"

  test "assigning a new scope over a live one keeps the new value":
    var env = scopedEnv([(Name, "old")])
    env = scopedEnv([(Name, "new")])
    check getEnv(Name) == "new"
    env = nil
    check not existsEnv(Name)
