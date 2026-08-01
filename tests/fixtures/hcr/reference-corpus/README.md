# HCR Reference Corpus Fixtures

These checked-in seed trees are deterministic, minimal stand-ins for the large
upstream reference checkouts named in `reference_corpus_map.nim`.

The integration test materializes each seed tree as a local git checkout under
`build/hcr-reference-corpus/` and verifies the generated commit id. This keeps
the full suite hermetic while still proving that the HCR reference metadata maps
to concrete source and documentation files.
