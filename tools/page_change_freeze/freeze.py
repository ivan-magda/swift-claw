#!/usr/bin/python3 -I
"""Isolated bootstrap for the page-change freeze CLI."""

from __future__ import annotations

import importlib
import importlib.util
from pathlib import Path
import sys


def reject_import_artifacts(package_root: Path) -> None:
    forbidden = {".pyc", ".pyo", ".so", ".dylib", ".pyd"}
    if any(path.is_symlink() or path.suffix in forbidden or "__pycache__" in path.parts
           for path in package_root.rglob("*")):
        raise SystemExit("error: verifier package contains a forbidden import artifact")


def isolated_main() -> int:
    """Load and run the protected CLI without trusting ambient import paths."""
    package_root = Path(__file__).resolve().parent
    reject_import_artifacts(package_root)
    sys.dont_write_bytecode = True
    package_name = "_swift_claw_page_change_freeze"
    try:
        specification = importlib.util.spec_from_file_location(
            package_name,
            package_root / "__init__.py",
            submodule_search_locations=[str(package_root)],
        )
        if specification is None or specification.loader is None:
            raise SystemExit("error: cannot load the fixed verifier package")
        package = importlib.util.module_from_spec(specification)
        sys.modules[package_name] = package
        specification.loader.exec_module(package)
        return importlib.import_module(f"{package_name}.cli").main()
    finally:
        reject_import_artifacts(package_root)


if __name__ == "__main__":
    if __package__ not in {None, ""}:
        raise SystemExit("error: invoke the verifier through its isolated script path")
    raise SystemExit(isolated_main())
