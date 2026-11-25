version       = "0.1.0"
author        = "Metacraft Labs"
description   = "HCR object LinkGraph facts, relocation classification, and pure patch planning"
license       = "Apache-2.0"
srcDir        = "src"
requires "nim >= 2.2.0"
# Every in-repo package the sources import. Consumers outside this checkout
# (the reprobuild-cmake HCR gates) derive their search path from these lines;
# tests/t_linkgraph_compiles_from_its_package_manifest_alone.nim holds the
# list to the imports in both directions.
requires "repro_core"
requires "repro_hash"
