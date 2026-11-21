## The fixture's test binary: three `testCase`s and a `main:`, built with
## `main` so that `--entrypoint=tests --list` runs no test. Each test prints
## a marker no other test prints, so a run's output says which tests it ran.

import entrypoints
import entrypoints/tests

testCase "alpha":
  echo "CSM14MARKER alpha"

testCase "beta":
  echo "CSM14MARKER beta" # beta's body

testCase "gamma":
  echo "CSM14MARKER gamma"

main:
  echo "CSM14MARKER main"
