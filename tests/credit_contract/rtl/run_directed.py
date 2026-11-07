#!/usr/bin/env python3
"""Run retained isolated RTL tests; this does not compile or execute UVM."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CASES = (
    ("tb_credit_fifo", ROOT / "rtl/i2c_credit_slave.sv"),
    ("tb_master_write", ROOT / "rtl/i2c_master.sv"),
)


def run(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=60)
    if result.returncode:
        print(result.stdout, end="")
        print(result.stderr, end="")
        raise SystemExit("failed: " + " ".join(str(part) for part in command))
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", choices=("all", "iverilog", "verilator"), default="all")
    args = parser.parse_args()
    simulators = ("iverilog", "verilator") if args.simulator == "all" else (args.simulator,)
    for simulator in simulators:
        if not shutil.which(simulator):
            raise SystemExit("required simulator is unavailable: " + simulator)
    with tempfile.TemporaryDirectory(prefix="i2c-credit-directed-") as temporary:
        build = Path(temporary)
        for simulator in simulators:
            version_flag = "-V" if simulator == "iverilog" else "--version"
            print(run([simulator, version_flag]).splitlines()[0])
            for top, source in CASES:
                harness = HERE / (top + ".sv")
                if simulator == "iverilog":
                    binary = build / (top + ".vvp")
                    run([simulator, "-g2012", "-s", top, "-o", str(binary), str(source), str(harness)])
                    output = run(["vvp", str(binary)])
                else:
                    directory = build / (top + "_verilator")
                    run([simulator, "--binary", "--timing", "--Wno-fatal", "--top-module", top,
                         "--Mdir", str(directory), str(source), str(harness)])
                    output = run([str(directory / ("V" + top))])
                if "PASS " + top not in output:
                    raise SystemExit("missing success marker for " + simulator + ": " + top)
                print("[" + simulator + "] " + output.strip())


if __name__ == "__main__":
    main()
