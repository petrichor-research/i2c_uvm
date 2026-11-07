#!/usr/bin/env python3
"""Type/elaborate the actual repository with external Accellera UVM 1.2."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shlex

import pyslang


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uvm-home", type=Path, required=True,
                        help="Extracted official UVM 1.2 directory containing src/uvm_pkg.sv")
    parser.add_argument("--repo", type=Path, default=REPO)
    parser.add_argument("--positive-control", action="store_true",
                        help="Inject an absent config member in memory to verify semantic checking")
    args = parser.parse_args()
    if pyslang.__version__ != "11.0.0":
        parser.error("This check is pinned to pyslang 11.0.0")
    repo = args.repo.resolve()
    uvm = args.uvm_home.resolve() / "src"
    for required in (uvm / "uvm_pkg.sv", uvm / "uvm_macros.svh"):
        if not required.is_file():
            parser.error("Missing external UVM source: " + str(required))

    driver = pyslang.driver.Driver()
    driver.addStandardArgs()
    if args.positive_control:
        # This is a compiler-input buffer, not an edit to the user's source.
        probe = repo / "src/tests/i2c_credit_test_base.sv"
        original = probe.read_text()
        replacement = original.replace(
            "scenario_completed = 0;",
            "scenario_completed = 0; cfg.SEMANTIC_POSITIVE_CONTROL_MISSING_FIELD = 0;", 1)
        if replacement == original:
            parser.error("Positive-control insertion point is absent")
        driver.sourceManager.assignText(str(probe), replacement)

    files = [repo / "src/i2c_if.sv", uvm / "uvm_pkg.sv", repo / "src/i2c_pkg.sv",
             repo / "src/i2c_test_pkg.sv", repo / "rtl/i2c_slave.sv", repo / "rtl/i2c_master.sv",
             repo / "rtl/i2c_credit_slave.sv", repo / "sim/tb_top.sv"]
    command = ["slang", "-I" + str(uvm), "-I" + str(repo / "src"), "-DUVM_NO_DPI",
               "--timescale=1ns/1ps", "--top", "tb_top", "--error-limit=80"]
    command.extend(str(path) for path in files)
    print("PYSLANG", pyslang.__version__, flush=True)
    print("COMMAND", shlex.join(command), flush=True)
    for path in files:
        print("SOURCE", path, "sha256=" + hashlib.sha256(path.read_bytes()).hexdigest(), flush=True)
    print("SCOPE actual UVM macros/library; UVM_NO_DPI; no simulation or vendor FSDB define", flush=True)
    if not (driver.parseCommandLine(shlex.join(command)) and driver.processOptions() and driver.parseAllSources()):
        return 2
    compilation = driver.createCompilation()
    diagnostics = list(compilation.getAllDiagnostics())
    errors = [diagnostic for diagnostic in diagnostics if diagnostic.isError()]
    print("RAW_ERROR_COUNT", len(errors), flush=True)
    for diagnostic in errors:
        print("SEMANTIC_ERROR", diagnostic.code, list(diagnostic.args), flush=True)
    driver.reportCompilation(compilation, False)
    success = driver.reportDiagnostics(False)
    if args.positive_control:
        caught = any("SEMANTIC_POSITIVE_CONTROL_MISSING_FIELD" in str(diagnostic.args)
                     for diagnostic in errors)
        print("POSITIVE_CONTROL_DETECTED", caught, flush=True)
        return 0 if caught else 1
    print("RESULT", "PASS real-UVM type/elaboration" if success else "FAIL real-UVM type/elaboration", flush=True)
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
