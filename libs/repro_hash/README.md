# repro_hash

Reprobuild hash policy library. CAS and cross-machine identities use BLAKE3-256.
Local invalidation uses GxHash only when a real implementation is available;
otherwise it selects the real XXH3 fallback and reports that decision.
