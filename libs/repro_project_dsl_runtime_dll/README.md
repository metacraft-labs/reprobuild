# repro_project_dsl_runtime_dll

Shared provider DSL runtime library.

This library builds the shared DSL runtime artifact shipped next to the
Reprobuild executable. Per-project providers can link against that artifact
instead of embedding the stable DSL and provider runtime surface in every
compiled provider binary.
