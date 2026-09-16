import std/unittest

import repro_hcr_agent/dispatch_table

suite "dispatch C implementation builds without external feature macros":
  test "empty transactions can be created and committed":
    check rollbackLogCount() == 0
    let first = beginTransaction()
    check first > 0
    check activeTransaction() == first
    check commitTransaction(first)
    let second = beginTransaction()
    check second > first
    check activeTransaction() == second
    check commitTransaction(second)
    check rollbackLogCount() == 0
    setActiveTransaction(0)
