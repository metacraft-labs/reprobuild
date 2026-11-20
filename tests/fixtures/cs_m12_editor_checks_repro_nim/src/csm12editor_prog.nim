## The fixture's program: it imports its project's ``repro.nim``, whose
## ``build:`` body does not compile, and must get the thin mode.

import ../repro

static:
  doAssert $fixtureDslMode == "rdmThin",
    "repro.nim compiled in " & $fixtureDslMode & ", not the thin mode"

echo "mode=", fixtureDslMode
