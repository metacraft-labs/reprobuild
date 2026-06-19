# M4 fixture program for trace-based incremental testing.
#
# A larger Python library (>=15 functions, a call graph >=3 levels deep) with
# three hand-built CodeTracer JSON traces — one per test — under ../trace_a,
# ../trace_b, ../trace_c. Each test's trace's Call stream records exactly the
# functions THAT test executed (runtime dependencies are transitive by
# construction: a callee that ran appears directly in the caller test's set).
#
# Call graph (-> = "calls", levels counted from the test entry point):
#
#   test_a entry -> run_a   (L1)
#                   run_a   -> mid_a       (L2)
#                              mid_a       -> leaf_shared  (L3)
#                              mid_a       -> leaf_a_only  (L3)
#                              mid_a       -> helper_one   (L3)
#                                             helper_one   -> leaf_deep (L4)
#
#   test_b entry -> run_b   (L1)
#                   run_b   -> mid_b       (L2)
#                              mid_b       -> leaf_shared  (L3)
#                              mid_b       -> leaf_b_only  (L3)
#                              mid_b       -> helper_two   (L3)
#
#   test_c entry -> run_c   (L1)
#                   run_c   -> mid_c       (L2)
#                              mid_c       -> compute      (L3)
#                                             compute      -> validate (L4)
#                                             compute      -> transform(L4)
#                              mid_c       -> helper_three (L3)
#
# Defined but NEVER executed by any test: dead_code, unused_helper.
#
# Per-test executed-function SETS (this is the whole point of the fixture):
#   test_a: run_a, mid_a, leaf_shared, leaf_a_only, helper_one, leaf_deep
#   test_b: run_b, mid_b, leaf_shared, leaf_b_only, helper_two
#   test_c: run_c, mid_c, compute, validate, transform, helper_three
#
# Notable functions for the M4 tests:
#   leaf_shared  -> executed by test_a AND test_b, NOT test_c (shared leaf).
#   leaf_a_only  -> executed by ONLY test_a (disjoint function).
#   leaf_deep    -> executed by test_a via run_a->mid_a->helper_one->leaf_deep
#                   (transitive callee, depth 4); it IS in test_a's trace set.
#   dead_code / unused_helper -> defined, executed by no test.
#
# Definition lines (1-based) are pinned below and MUST stay in sync with the
# `line` fields in the trace files. Each function is a simple `def name(...):`
# with a single-statement body so M1-style body edits are easy and local.
#
# Pinned def lines:
#   leaf_shared   -> 69
#   leaf_a_only   -> 73
#   leaf_b_only   -> 77
#   leaf_deep     -> 81
#   helper_one    -> 85
#   helper_two    -> 89
#   helper_three  -> 93
#   compute       -> 97
#   validate      -> 101
#   transform     -> 105
#   mid_a         -> 109
#   mid_b         -> 113
#   mid_c         -> 117
#   run_a         -> 121
#   run_b         -> 125
#   run_c         -> 129
#   dead_code     -> 133
#   unused_helper -> 137

def leaf_shared(x):
    return x + 1


def leaf_a_only(x):
    return x * 2


def leaf_b_only(x):
    return x - 3


def leaf_deep(x):
    return x * x


def helper_one(x):
    return leaf_deep(x) + 7


def helper_two(x):
    return x + 11


def helper_three(x):
    return x + 13


def compute(x):
    return validate(x) + transform(x)


def validate(x):
    return x if x > 0 else 0


def transform(x):
    return x << 1


def mid_a(x):
    return leaf_shared(x) + leaf_a_only(x) + helper_one(x)


def mid_b(x):
    return leaf_shared(x) + leaf_b_only(x) + helper_two(x)


def mid_c(x):
    return compute(x) + helper_three(x)


def run_a(x):
    return mid_a(x)


def run_b(x):
    return mid_b(x)


def run_c(x):
    return mid_c(x)


def dead_code(x):
    return x + 999


def unused_helper(x):
    return x - 999
