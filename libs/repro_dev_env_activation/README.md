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
