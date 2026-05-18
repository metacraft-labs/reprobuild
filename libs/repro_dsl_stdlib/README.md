# Reprobuild DSL Standard Library

Initial standard-library modules for project DSL files. Import
`repro_dsl_stdlib` for the default prelude.

The first module is `fs`, which exposes built-in filesystem operations that
lower to typed Reprobuild graph actions instead of shell snippets.
