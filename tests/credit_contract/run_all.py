#!/usr/bin/env python3
"""Run isolated contract checks, not the VCS/UVM integration regression."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, help="Retain commands, output, and source hashes as JSON")
    parser.add_argument("--uvm-home", type=Path, help="Also type/elaborate against external official UVM 1.2; needs pyslang 11")
    args = parser.parse_args()
    commands = [
        [sys.executable, str(HERE / "rtl/run_directed.py"), "--simulator", "all"],
        [sys.executable, str(HERE / "sampling/run_directed.py")],
        [sys.executable, str(HERE / "accounting/run_directed.py")],
        [sys.executable, str(HERE / "events/run_directed.py")],
        [sys.executable, str(HERE / "encoding/run_directed.py")],
        [sys.executable, "-B", "-m", "unittest", "discover", "-s",
         "tests/credit_contract", "-p", "test_regression_runner.py", "-v"],
    ]
    if args.uvm_home:
        semantic = [sys.executable, str(HERE / "semantic/check_with_real_uvm.py"),
                    "--uvm-home", str(args.uvm_home.resolve())]
        commands.extend([semantic, semantic + ["--positive-control"]])
    files = list((ROOT / "src").rglob("*.sv")) + list((ROOT / "rtl").glob("*.sv"))
    files += [ROOT / "sim/tb_top.sv", ROOT / "sim/Makefile", ROOT / "sim/run_credit_regression.py"]
    files += [p for p in HERE.rglob("*") if p.is_file() and p.suffix in (".py", ".sv", ".md")]
    hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(files)}
    results = []
    for command in commands:
        print("RUN " + " ".join(command), flush=True)
        started = time.monotonic()
        try:
            completed = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=240)
            output = completed.stdout + completed.stderr
            code = completed.returncode
        except subprocess.TimeoutExpired as error:
            output = str(error)
            code = 124
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
        results.append({"command": command, "returncode": code, "output": output,
                        "elapsed_seconds": round(time.monotonic() - started, 3)})
    report = {"scope": "Isolated RTL, extracted-method, fake-process runner checks, and optional real-UVM type/elaboration; no VCS/UVM execution",
              "source_sha256": hashes, "checks": results,
              "passed_groups": sum(r["returncode"] == 0 for r in results),
              "total_groups": len(results)}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print("RESULT {}/{} isolated check groups passed".format(report["passed_groups"], len(results)))
    return 0 if all(r["returncode"] == 0 for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
