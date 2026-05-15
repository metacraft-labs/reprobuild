# Fs Snoop Tool

Tiny file-observation fixture for the future `repro-fs-snoop` path. The tool
reads one file and writes a normalized copy, giving monitor tests concrete read
and write paths without requiring platform-specific monitoring yet.

Expected command shape:

```sh
cc src/fs_snoop_tool.c -o build/fs-snoop-tool
./build/fs-snoop-tool fixtures/input.txt build/output.txt
```
