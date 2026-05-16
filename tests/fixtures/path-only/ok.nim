import repro_project_dsl

package pathOnlyOk:
  uses:
    "m8-fixture-tool >=1.0 <2.0"

  executable pathOnlyDemo:
    name "path-only-demo"
    cli:
      subcmd "check":
        flag verbose, bool
