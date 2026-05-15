# Windows Dev Env

Deferred Windows development-environment fixture. M0 checks only that the
repository carries a concrete example directory; Windows environment realization
and Scoop-backed provisioning are future work.

The source is intentionally tiny and guarded with `_WIN32` so future Windows CI
can use it without implying Linux or macOS support for this example.
