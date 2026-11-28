## The same tests in a binary WITHOUT the tests entry, which reads its
## arguments the way `std/unittest` does where it does not know the entry
## (upstream Nim's, or the codetracer Nim fork's before it answered the
## entry): every argument is a test filter, and a filter that names no test
## selects none. So `--entrypoint=list` prints no entry list, runs nothing
## and exits 0, and `--entrypoint=tests --run-exact=math::mul` runs nothing
## and passes. That is the binary the producer's `--entrypoint=list` probe
## exists for: it must run it as a whole, never per test.
##
## It does not import `std/unittest` (whose pinned version would answer the
## entry), and keeps its own `test` and `check` to the minimum the fixture's
## sources share: a filter is a test's full name, compared as written.

import std/os

var
  filters: seq[string]
  failed = false

for i in 1 .. paramCount():
  filters.add paramStr(i)

template check(condition: bool) =
  if not condition:
    echo "check failed: ", astToStr(condition)
    failed = true

template test(name: string; body: untyped) =
  if filters.len == 0 or name in filters:
    body

test "math::add":
  echo "CSM14SHIM math::add"

test "math::mul":
  echo "CSM14SHIM math::mul" # mul's body

test "loose":
  echo "CSM14SHIM loose"

if failed:
  quit(1)
