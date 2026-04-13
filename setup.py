"""
Custom setup.py that runs ``zig build`` before installing the Python package.

This lets users simply run ``pip install -e .`` (or ``pip install .``) without
needing the separate ``tools/build_and_install.sh`` script.  The Zig build
produces ``zig-out/lib/libspout.so`` which ``spout.ffi`` discovers at runtime.
"""

import subprocess
import sys
from pathlib import Path

from setuptools import setup
from setuptools.command.build_ext import build_ext
from setuptools.command.develop import develop
from setuptools.command.install import install


PROJECT_ROOT = Path(__file__).resolve().parent


def _run_zig_build() -> None:
    """Invoke ``zig build`` in the project root if build.zig exists."""
    build_zig = PROJECT_ROOT / "build.zig"
    if not build_zig.exists():
        # Installed from sdist without the Zig source -- skip.
        return

    lib_path = PROJECT_ROOT / "zig-out" / "lib" / "libspout.so"
    if lib_path.exists():
        # Already built -- skip to avoid slowing down repeated installs.
        # Users can force a rebuild with ``zig build`` manually.
        return

    print("Running `zig build` to compile libspout.so ...")
    try:
        subprocess.check_call(
            ["zig", "build"],
            cwd=str(PROJECT_ROOT),
        )
    except FileNotFoundError:
        print(
            "WARNING: `zig` not found on PATH.  Skipping native build.\n"
            "Install Zig (https://ziglang.org) and run `zig build` manually,\n"
            "or set SPOUT_LIB_PATH to a pre-built libspout.so.",
            file=sys.stderr,
        )
    except subprocess.CalledProcessError as exc:
        print(
            f"WARNING: `zig build` failed (exit code {exc.returncode}).\n"
            "Run `zig build` manually to see full error output.",
            file=sys.stderr,
        )


class ZigBuildExt(build_ext):
    """Custom build_ext that triggers ``zig build`` first."""

    def run(self) -> None:
        _run_zig_build()
        super().run()


class ZigDevelop(develop):
    """Custom develop (editable install) that triggers ``zig build`` first."""

    def run(self) -> None:
        _run_zig_build()
        super().run()


class ZigInstall(install):
    """Custom install that triggers ``zig build`` first."""

    def run(self) -> None:
        _run_zig_build()
        super().run()


setup(
    cmdclass={
        "build_ext": ZigBuildExt,
        "develop": ZigDevelop,
        "install": ZigInstall,
    },
)
