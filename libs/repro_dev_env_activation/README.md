# repro_dev_env_activation

Development-environment activation helpers.

This library renders shell fragments from canonical development-environment
artifacts. It supports POSIX shells, fish, PowerShell, and JSON inspection output.

`runActivatedCommand` starts a command and waits, returning its exit status to
the library caller. `execActivatedCommand` replaces the caller's process image
on POSIX, so supervisors can signal the command through the original PID and
observe its normal exit or signal termination directly. On Windows it starts
the command and waits. Both preserve the activated argv, environment and working
directory. Replacement failures raise an error and restore the caller's working
directory.

On Windows x64, command activation also locates the existing Visual Studio
host facility for declared MSVC consumers. It reuses the platform environment
merger, preserving caller and recipe compiler/linker choices. MinGW-only and
inactive tool declarations do not activate MSVC, and this adds no native ARM
activation. An unavailable host toolset remains diagnosed by the existing
locator; no installer is run. Printed artifact data remains project data, not
a snapshot of the current host's Visual Studio installation.
