version = "0.1.0"
author = "Metacraft Labs"
description = "Reprobuild hash policy"
license = "Apache-2.0"
srcDir = "src"
requires "nim >= 2.2.0"
# In-repo packages the sources import (repro_hcr_linkgraph's consumers reach
# them through this manifest).
requires "blake3"
requires "gxhash"
requires "xxh3"
