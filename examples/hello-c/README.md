# Hello C

Minimal C project fixture for the first Reprobuild local-build examples. It is
small enough for layout and smoke tests while still containing real source that
can be compiled by future build-engine tests.

Expected command shape:

```sh
cc src/hello.c -o build/hello-c
./build/hello-c
```

Expected output:

```text
hello from C
```
