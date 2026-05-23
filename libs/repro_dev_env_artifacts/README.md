# repro_dev_env_artifacts

M2 development-environment artifact domain type, binary codec, navigator hot
path, and JSON inspection surface.

The canonical payload is encoded by status-im/nim-ssz-serialization. Reprobuild
wraps that payload in a small RBDE envelope with a trailing BLAKE3 checksum; JSON
is derived inspection output only.
