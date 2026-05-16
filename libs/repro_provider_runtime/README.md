# Repro Provider Runtime

Small fixed-schema provider graph runtime used by the M18 integration gate.

It implements a file-backed binary provider request/response protocol, a
binary fragment snapshot store, and host-side fragment refresh/pruning rules.
It does not schedule build actions or execute cleanup.
