#!/usr/bin/env python3
"""Export compiler ABIs, or check the delivered ABI files without changing them."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = root / "docs" / "abi"
    failed = False
    for name in ("LaunchToken", "GrantExecutor", "CityRegistry"):
        result = subprocess.run(
            ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        encoded = json.dumps(json.loads(result.stdout), indent=2) + "\n"
        path = output / f"{name}.json"
        if args.check:
            if not path.exists() or path.read_text() != encoded:
                print(f"ABI differs: {path.relative_to(root)}", file=sys.stderr)
                failed = True
        else:
            output.mkdir(parents=True, exist_ok=True)
            path.write_text(encoded)
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
