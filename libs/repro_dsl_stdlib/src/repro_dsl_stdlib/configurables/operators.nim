## Operator overloads on `Configurable[T]`. The contract:
##
##   "For each operator, if any operand is a configurable, the
##    result is a configurable."
##
## We implement enough operators here to satisfy the Validation
## Criteria in `Configurable-System.md`: arithmetic on
## `Configurable[int]`, string concatenation on
## `Configurable[string]`, comparison, `$` stringification, and a
## `.len` reader for collections.

import ./types
import ./context
import ./api

# ---------------------------------------------------------------------------
# Internal: build a one-input compute node
# ---------------------------------------------------------------------------

proc makeNode1[T, R](parent: Configurable[T];
                     compute: proc(a: T): R): Configurable[R] =
  let ctx = currentContext()
  let aId = parent.id
  let fn = proc(values: openArray[ConfigurableValue]):
           ConfigurableValue =
    let av = unwrapValue[T](values[0])
    wrapValue(compute(av))
  let node = ctx.allocNode("", valueKindOf(R))
  node.deps = @[aId]
  node.compute = fn
  Configurable[R](id: node.id)

proc makeNode2[A, B, R](a: Configurable[A]; b: Configurable[B];
                        compute: proc(a: A; b: B): R): Configurable[R] =
  let ctx = currentContext()
  let aId = a.id
  let bId = b.id
  let fn = proc(values: openArray[ConfigurableValue]):
           ConfigurableValue =
    let av = unwrapValue[A](values[0])
    let bv = unwrapValue[B](values[1])
    wrapValue(compute(av, bv))
  let node = ctx.allocNode("", valueKindOf(R))
  node.deps = @[aId, bId]
  node.compute = fn
  Configurable[R](id: node.id)

# ---------------------------------------------------------------------------
# Arithmetic on Configurable[int]
# ---------------------------------------------------------------------------

proc `+`*(a: Configurable[int]; b: int): Configurable[int] =
  makeNode1[int, int](a, proc(x: int): int = x + b)
proc `+`*(a: int; b: Configurable[int]): Configurable[int] =
  makeNode1[int, int](b, proc(x: int): int = a + x)
proc `+`*(a, b: Configurable[int]): Configurable[int] =
  makeNode2[int, int, int](a, b, proc(x, y: int): int = x + y)

proc `-`*(a: Configurable[int]; b: int): Configurable[int] =
  makeNode1[int, int](a, proc(x: int): int = x - b)
proc `-`*(a: int; b: Configurable[int]): Configurable[int] =
  makeNode1[int, int](b, proc(x: int): int = a - x)
proc `-`*(a, b: Configurable[int]): Configurable[int] =
  makeNode2[int, int, int](a, b, proc(x, y: int): int = x - y)

proc `*`*(a: Configurable[int]; b: int): Configurable[int] =
  makeNode1[int, int](a, proc(x: int): int = x * b)
proc `*`*(a: int; b: Configurable[int]): Configurable[int] =
  makeNode1[int, int](b, proc(x: int): int = a * x)
proc `*`*(a, b: Configurable[int]): Configurable[int] =
  makeNode2[int, int, int](a, b, proc(x, y: int): int = x * y)

# ---------------------------------------------------------------------------
# Comparison: returns Configurable[bool]
# ---------------------------------------------------------------------------

proc `==`*(a: Configurable[int]; b: int): Configurable[bool] =
  makeNode1[int, bool](a, proc(x: int): bool = x == b)
proc `<`*(a: Configurable[int]; b: int): Configurable[bool] =
  makeNode1[int, bool](a, proc(x: int): bool = x < b)
proc `<=`*(a: Configurable[int]; b: int): Configurable[bool] =
  makeNode1[int, bool](a, proc(x: int): bool = x <= b)

# ---------------------------------------------------------------------------
# String concatenation
# ---------------------------------------------------------------------------

proc `&`*(a: Configurable[string]; b: string): Configurable[string] =
  makeNode1[string, string](a, proc(x: string): string = x & b)
proc `&`*(a: string; b: Configurable[string]): Configurable[string] =
  makeNode1[string, string](b, proc(x: string): string = a & x)
proc `&`*(a, b: Configurable[string]): Configurable[string] =
  makeNode2[string, string, string](a, b,
    proc(x, y: string): string = x & y)

# ---------------------------------------------------------------------------
# Stringify int configurable
# ---------------------------------------------------------------------------

proc `$`*(c: Configurable[int]): Configurable[string] =
  makeNode1[int, string](c, proc(x: int): string = $x)

proc `$`*(c: Configurable[bool]): Configurable[string] =
  makeNode1[bool, string](c, proc(x: bool): string = $x)

# ---------------------------------------------------------------------------
# .len on a Configurable[string]
# ---------------------------------------------------------------------------

proc len*(c: Configurable[string]): Configurable[int] =
  makeNode1[string, int](c, proc(x: string): int = x.len)
