## Macro-overloaded `.` (dot) operator for `ConfigurableVal[T]`.
##
## During the staged phase, `c.val` returns a `ConfigurableVal[T]`,
## and an expression like `c.val.host` is rewritten by this macro
## into a `mapClosureImpl` call that reads the named field from the
## resolved value of `c`. The macro is a real macro (not a template)
## so it can synthesize the closure with the correct parameter type.

{.experimental: "dotOperators".}

import std/[macros]

import ./types
import ./api

macro `.`*(proxy: ConfigurableVal; field: untyped): untyped =
  ## Staged field read. Lowers `proxy.field` to:
  ##
  ##   mapClosureImpl(proxy.parent, ".field",
  ##     proc(v: typeof(proxy.parent.read(...))): auto = v.field)
  ##
  ## The closure's argument type is captured via `typeof` so the
  ## macro does not need to know `T` directly at expansion.
  let fieldName = $field
  let parentExpr = newDotExpr(proxy, ident"parent")
  let vSym = genSym(nskParam, "v")
  let typeofCall = newCall(bindSym"typeof",
    newCall(bindSym"unwrapValue",
      newCall(bindSym"wrapValue", newDotExpr(parentExpr, ident"id"))))
  # Build: proc(v: T): auto = v.field, where T is inferred via the
  # `mapClosureImpl` overload's first argument type.
  let parentExpr2 = newDotExpr(proxy, ident"parent")
  result = quote do:
    block:
      let parentHandle = `parentExpr2`
      mapClosureImpl(parentHandle, "." & `fieldName`,
        proc(v: typeof(read(currentContext(), parentHandle))): auto =
          v.`field`)
  # Use the `unused` typeof variable to keep imports referenced.
  discard typeofCall
  discard vSym

macro `.=`*(proxy: ConfigurableVal; field: untyped;
            value: untyped): untyped =
  ## Mutable field assignment is rejected at macro expansion. The
  ## emitted error references `EConfigurableMutation` by name so the
  ## acceptance test can grep for it without depending on Nim's
  ## diagnostic phrasing.
  let fieldName = $field
  error("EConfigurableMutation: mutable field assignment on a " &
        "ConfigurableVal is not allowed (offending field: ." &
        fieldName & "). Mutations go through `.override`, not `.val`.",
        field)
