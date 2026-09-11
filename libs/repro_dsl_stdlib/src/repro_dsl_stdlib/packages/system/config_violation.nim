## The one exception a system-scope package raises when a configuration
## the DSL accepted is not one the package can honour.
##
## ## Why it is here rather than in the package that first needed it
##
## `reproos_desktop` declared this type, because it was the first
## system-scope package whose specification carried a cross-field
## constraint the declaration DSL cannot express (see that module's
## "DSL limitation" section — a `validate:` rule inside a package or
## activity body is not a form `parsePackageDef` or the `activity` macro
## parses, so the constraint is enforced by a hand-written proc instead).
##
## It is no longer the only one. A caller that wants to say "this
## configuration was rejected by the package, not by the compiler and not
## by the operating system" should be able to catch ONE type and mean
## exactly that, whichever package raised it. Two identically named
## exceptions in two modules would have made that a guess about which
## module the value came from, and a `try` that caught one of them would
## have silently not caught the other.
##
## ## Mocking
##
## None. This module is a type declaration.

type
  EConfigViolation* = object of CatchableError
    ## A system-scope package was handed a configuration it refuses.
    ##
    ## The configuration is well-typed — it compiled — and every field
    ## is individually legal. What it violates is a constraint BETWEEN
    ## fields, or between a field and the environment the package will
    ## run in. Those are the constraints a specification writes as a
    ## `validate:` rule and that no type can carry on its own.
    ##
    ## Raised during evaluation of a profile, so it surfaces to the
    ## operator as a failed `repro infra plan` rather than as a machine
    ## that boots into a state nobody asked for.
