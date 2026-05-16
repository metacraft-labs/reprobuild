# repro_hcr_test

Strict fake target environment for direct-HCR prototype gates. It models
executable memory regions, W^X protections, patch generations, trampoline
dispatch, instruction-cache flush evidence, and old-code retention.

This library is test support only; production HCR code must not import it.
