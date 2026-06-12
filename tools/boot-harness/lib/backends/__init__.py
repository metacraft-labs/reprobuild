"""Backend drivers exporting a ``HarnessSession``-conformant class each.

- ``hyperv.HyperVSession``
- ``wsl2.WSL2Session``
- ``qemu.QEMUSession``
"""

from importlib import import_module

_BACKENDS = ("hyperv", "wsl2", "qemu")


def load(name: str):
    if name not in _BACKENDS:
        raise ValueError(f"unknown backend {name!r} (known: {_BACKENDS})")
    return import_module(f"lib.backends.{name}")
