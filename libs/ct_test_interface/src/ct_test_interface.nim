## ct_test_interface — The `TestBinary` contract.
##
## Per-framework adapters (`ct_test_nim_unittest`, future
## `ct_test_cargo`, `ct_test_pytest`, …) import this module and produce
## typed handles whose Nim shape follows the conventions below.
##
## Reprobuild's typed-output machinery binds an adapter's typed-handle
## type to a build edge via the `outputs <field> is <Type>, <path>`
## syntax — see reprobuild-specs/Package-Model.md §"Typed Outputs".
## Reprobuild populates the handle by calling
## `<HandleType>(path: <pathValue>)`, so every typed-handle type must
## support that object-constructor syntax.

import ct_test_interface/types
export types
