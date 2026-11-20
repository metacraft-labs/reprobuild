## A scratch directory inside the checkout, for a test whose probe has to be
## compiled against this checkout's ``config.nims`` (Nim finds it by walking
## up from the probe, so the probe must sit below the checkout root).
##
## NOT IN THE ROOT. ``fresh_binary`` refuses a helper in ``build/bin`` when a
## directory its compile listed has changed since (§13 decisions 80 and 86),
## and every helper whose package search reaches the root lists the root:
## Nim's ``getNimbleFile`` globs ``*.nimble`` in each parent directory of a
## module up to the first one that has one. A scratch entry created in the
## root while another case checks a helper's freshness is a race on that
## digest. Under ``build/`` -- ignored, and below no module any helper
## compiles -- it is listed by nothing.

import std/[os, tempfiles]

proc inTreeScratchDir*(prefix: string; repoRoot = getCurrentDir()): string =
  ## A new, empty directory under ``<repoRoot>/build/test-scratch/``. The
  ## caller removes it.
  let parent = repoRoot / "build" / "test-scratch"
  createDir(parent)
  createTempDir(prefix, "", parent)
