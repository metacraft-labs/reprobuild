# Io Monitor Tool

Tiny file-observation fixture for the io-monitor path. The tool
reads one file and writes a normalized copy, giving monitor tests concrete read
and write paths without requiring platform-specific monitoring yet.

Expected command shape:

```sh
cc src/io_monitor_tool.c -o build/io-monitor-tool
./build/io-monitor-tool fixtures/input.txt build/output.txt
```
