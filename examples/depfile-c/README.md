# Depfile C

Small C fixture that exercises generated header dependencies through a Make/Ninja
style depfile. Future dependency-evidence tests can compile `src/main.c` with
`-MMD -MF build/main.d` and verify that `src/message.h` is recorded.

Expected command shape:

```sh
cc -MMD -MF build/main.d -c src/main.c -o build/main.o
cc build/main.o -o build/depfile-c
```
