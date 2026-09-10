## Sample project binary #1 for the M0 packaging gate.
##
## It prints the value of an environment variable the §5 wrapper is
## supposed to have set. That is the point of the binary: "the package
## installed" is a weak claim, "the installed binary ran and observed
## the environment default the packaging layer promised to bake in" is
## the claim Distribution-And-Packaging.md §5 actually makes, and this
## is the smallest program that can carry it.
import std/[os, strutils]

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--env":
    echo getEnv("SAMPLETOOL_DATA_DIR", "<unset>")
  elif args.len > 0 and args[0] == "--mode":
    echo getEnv("SAMPLETOOL_MODE", "<unset>")
  else:
    echo "hello from sampletool ", args.join(" ")
