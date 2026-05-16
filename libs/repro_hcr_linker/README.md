# repro_hcr_linker

Small M27 direct-HCR transaction layer over the M26 patch-plan evidence. The
current support profile is intentionally narrow: AArch64 direct branch
trampolines for a minimal in-target fixture and the strict fake target test
double.

This library does not implement debugger/unwind registration, broad relocation
application, CodeTracer replay integration, or shared-library patch loading.
