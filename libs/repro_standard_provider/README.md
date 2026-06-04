# repro_standard_provider

Convention dispatch framework for `repro-standard-provider` (Tier 2b).

The standard provider's job is to turn a no-`build:` `reprobuild.nim`
into a fine-grained build graph by recognising the language's
conventional source layout. This library carries the framework pieces
— the `LanguageConvention` value type, the `ConventionRegistry`, and a
module-level `defaultConventionRegistry` for the provider to consult
at startup. Per-language plugin libraries (Nim, Rust, Go, …) plug in
by calling `addDefaultConvention` from their own startup code,
mirroring how `RegisterProvider` shows up in Tier 2c.

See `reprobuild-specs/Provider-Compile-Tiering.md` and
`reprobuild-specs/Language-Conventions/README.md` for the design
context.
