## ct_test_interface/types — Value types for the TestBinary contract.

type
  TestId* = string
    ## Fully-qualified test name (`<suite>::<test>` per the codetracer
    ## parallel test framework spec).

  TestBinary* = object of RootObj
    ## Base record for per-framework test-binary handles. Each adapter
    ## defines its own handle type that inherits from (or otherwise
    ## structurally matches) this shape. The `path` field is populated
    ## by reprobuild's typed-output binding at action-emission time.
    path*: string

  TestResultsHandle* = object
    ## Typed output of a `run`/`runTest` invocation. The `path` is
    ## where the binary wrote its result file (JSON per the Tier-1
    ## "Standard" protocol).
    path*: string

  TestCatalogHandle* = object
    ## Typed output of a `list`/`enumerate` invocation. The `path` is
    ## where the binary wrote its catalog file (one test name per line
    ## or JSON per the codetracer spec).
    path*: string
