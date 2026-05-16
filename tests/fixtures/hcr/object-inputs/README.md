# HCR Object Inputs

M25 uses these C sources only to produce old/new relocatable object files for
later direct-HCR linker work. The build script compiles with `-c`, `-g`,
`-ffunction-sections`, and `-fpatchable-function-entry=8,4`; it does not build
or load a shared library.

M26 adds tiny arm64 assembly sources that keep LinkGraph, relocation, debug, and
unwind facts reviewable. They are assembled as relocatable objects only; the
positive path never builds or loads a shared library.
