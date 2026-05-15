# Monitored Opaque Tool

Fixture for a tool whose inputs are discovered by monitoring instead of a
declared depfile. M0 only provides the concrete source and input file; monitor
execution semantics are deferred to later implementation slices.

Expected command shape:

```sh
cc src/opaque_transform.c -o build/opaque-transform
./build/opaque-transform fixtures/raw.txt build/result.txt
```
