# repro_monitor_shim

Reprobuild-specific monitor shim.

The injected macOS shim consumes the extracted sibling `ct_interpose` package
for interpose/original-call mechanics and writes binary monitor evidence
fragments that are merged into canonical `.rdep` files by
`repro_monitor_depfile`.
