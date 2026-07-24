## Typed-Extension-Interfaces M1b: ``unmarshalAttrs`` on a resource ``typeId``
## whose extension was NOT lifted / made visible in this compilation raises an
## ACTIONABLE diagnostic that points at the MISSING INTERFACE DEPENDENCY — not
## the pre-M1b "link the provider module" wording. M1b turns the fix into
## "import the producer's LIFTED interface" (which regenerates the attrs type
## and registers its SSZ codec without linking the provider/driver module), so
## the message must name that as the missing piece.
##
## Spec cite: ``Typed-Extension-Interfaces-And-Provider-Libraries.md`` §2; the
## M1b deliverable "``unmarshalAttrs`` for a typeId whose extension was NOT
## lifted/visible errors with an actionable message that points at the missing
## interface dependency".

import std/[strutils, unittest]

import repro_resources/marshal

suite "t_attr_missing_interface_diagnostic":

  test "unmarshalAttrs on an unlifted typeId points at the interface dependency":
    # A fresh registry (no ``registerExtension`` for this id) is exactly the
    # state a consumer compilation is in when it did NOT import the producer's
    # lifted interface.
    var raised = false
    try:
      discard unmarshalAttrs("vm_harness.unlifted", "\x01\x00\x00\x00\x00\x00")
    except KeyError as err:
      raised = true
      # Names the resource typeId that could not be re-hydrated.
      check err.msg.contains("vm_harness.unlifted")
      # Points at the MISSING INTERFACE DEPENDENCY (the M1b framing) …
      check err.msg.contains("missing the interface dependency")
      check err.msg.contains("lifted")
      # … and does NOT regress to the pre-M1b "link the provider module" text.
      check not err.msg.contains("must link the provider module")
    check raised
