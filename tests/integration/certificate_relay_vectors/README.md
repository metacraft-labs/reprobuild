# Signed relay regression fixtures

These two plain-data notes cases are copied byte for byte from
`test-certificates-spec` commit `71ab19e73018673abb92eca651e8ef783535911d`,
`vectors/notes/signed-copy-not-replaced` and
`vectors/notes/signed-duplicate-protects`.

They exercise relay preservation of an existing signed payload, including a
signed duplicate after an unsigned copy. They are focused regression fixtures;
the complete conformance suite continues to use its separately pinned revision.
