"""Top-level training dispatcher for the refactored Python surface."""

from __future__ import annotations

import argparse
import subprocess
import sys

MODULE_TO_ENTRYPOINT = {
    "surrogate": "python.surrogate.train",
    "constraint": "python.constraint.train",
    "gcnrl": "python.gcnrl.train",
    "unet": "python.unet.train",
}


def _run_entrypoint(entrypoint: str, extra_args: list[str]) -> int:
    """Run a module entrypoint in a subprocess and return its exit code."""
    cmd = [sys.executable, "-m", entrypoint, *extra_args]
    return subprocess.run(cmd, check=False).returncode


def main() -> None:
    """Dispatch training to one model package or to all packages in sequence."""
    parser = argparse.ArgumentParser(description="Refactored Spout training entrypoint")
    parser.add_argument(
        "--model",
        choices=[*MODULE_TO_ENTRYPOINT.keys(), "all"],
        default="all",
        help="Model package to train.",
    )
    parser.add_argument(
        "args",
        nargs=argparse.REMAINDER,
        help="Arguments forwarded to the selected module entrypoint(s).",
    )
    ns = parser.parse_args()

    forwarded = ns.args
    if forwarded and forwarded[0] == "--":
        forwarded = forwarded[1:]

    selected = (
        MODULE_TO_ENTRYPOINT.items()
        if ns.model == "all"
        else [(ns.model, MODULE_TO_ENTRYPOINT[ns.model])]
    )

    failures: list[str] = []
    for name, entrypoint in selected:
        rc = _run_entrypoint(entrypoint, forwarded)
        if rc != 0:
            failures.append(f"{name} (exit {rc})")

    if failures:
        raise SystemExit("Training failed for: " + ", ".join(failures))


if __name__ == "__main__":
    main()
