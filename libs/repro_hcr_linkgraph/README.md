# repro_hcr_linkgraph

Focused M26 implementation for HCR object parsing, LinkGraph fact extraction,
relocation classification, changed-function detection, and pure patch plan
evidence.

The current support profile is intentionally narrow: Mach-O 64-bit arm64
relocatable objects on macOS. It records debug and unwind facts but does not
apply target-memory mutations, install trampolines, register unwind/debug
metadata, or load shared libraries.
