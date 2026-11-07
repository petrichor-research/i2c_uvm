#!/usr/bin/env python3
"""Run seeded credit tests and fail closed on missing or inconsistent results.

Exit status alone is not a UVM oracle. Each run must report one passing TEST
STATUS marker and UVM_ERROR/UVM_FATAL summary counts. The directed error test
also requires exactly three TBI-1 errors and its explicit injection marker.
The exhaustion test requires one exact driver watchdog diagnostic, zero monitor
violation counters, and its explicit no-DATA-launch oracle marker.
"""

import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shlex
import subprocess


TESTS = (
    "i2c_credit_sanity_test", "i2c_credit_exhaustion_test",
    "i2c_credit_burst_test", "i2c_credit_error_test",
    "i2c_credit_dual_role_test", "i2c_credit_random_test",
)
ERROR_TEST = "i2c_credit_error_test"
EXHAUSTION_TEST = "i2c_credit_exhaustion_test"
EXPECTED_TBI1_ERRORS = 3
# This waiver belongs only to the one-byte, zero-budget injection scenario.
# Do not accept an arbitrary error merely because its text mentions TBI-1.
EXPECTED_INJECTION_DIAGNOSTIC = re.compile(
    r"\[CREDIT_MON\]\s+TBI-1 VIOLATION \(completion-time diagnostic\): "
    r"attempted=1 current_available=0 \(launch budget not observed\)\s*$"
)
EXPECTED_TIMEOUT_DIAGNOSTIC = re.compile(
    r"\[CBT_DRV\]\s+TBI-5 diagnostic timeout: pending DATA aborted without transmission\s*$"
)
EXPECTED_TIMEOUT_SUFFIX = r"\s*\(observed exactly 1 expected TBI-5 timeout; no DATA launch\)\s*"
EXPECTED_TIMEOUT_MARKER = re.compile(r"\s*TEST STATUS:\s*PASSED" + EXPECTED_TIMEOUT_SUFFIX)
ACCOUNTING_FAILURE = re.compile(
    r"\bTBI[-_ ]?[1-6]\b[^\n]*(?:\bVIOLATION\b|mismatch|failed|timeout)"
    r"|\b(?:accounting|conservation)\b[^\n]*(?:\bviolation\b|mismatch|failed)"
    r"|Error-injection oracle failed",
    re.IGNORECASE,
)


def merge_outputs(primary, console):
    """Include console-only diagnostics without counting mirrored logs twice."""
    remaining = Counter(primary.splitlines())
    additional = []
    for line in console.splitlines():
        if remaining[line]:
            remaining[line] -= 1
        else:
            additional.append(line)
    return primary + "\n" + "\n".join(additional)


def assess_output(test, output, returncode, timed_out=False):
    """Classify a complete simulator log without trusting its final line."""
    reasons = []
    if timed_out:
        reasons.append("wall-clock simulator timeout")
    if returncode != 0:
        reasons.append("simulator exit status {}".format(returncode))

    markers = re.findall(r"^\s*TEST STATUS:\s*(PASSED|FAILED)\b([^\n]*)",
                         output, re.MULTILINE)
    if len(markers) != 1 or markers[0][0] != "PASSED":
        reasons.append("expected exactly one passing TEST STATUS marker")

    counts = {}
    for severity in ("ERROR", "FATAL"):
        values = re.findall(r"^\s*UVM_" + severity + r"\s*:\s*(\d+)\s*$",
                            output, re.MULTILINE)
        if len(values) != 1:
            reasons.append("missing or repeated UVM_{} summary".format(severity))
            counts[severity] = None
        else:
            counts[severity] = int(values[0])

    error_lines = re.findall(r"^\s*UVM_ERROR\b(?!\s*:)[^\n]*",
                             output, re.MULTILINE)
    fatal_lines = re.findall(r"^\s*UVM_FATAL\b(?!\s*:)[^\n]*",
                             output, re.MULTILINE)
    if counts["FATAL"] != 0 or fatal_lines:
        reasons.append("UVM fatal diagnostic or nonzero fatal summary")

    expected_injection = test == ERROR_TEST
    expected_timeout = test == EXHAUSTION_TEST
    expected_errors = EXPECTED_TBI1_ERRORS if expected_injection else (1 if expected_timeout else 0)
    if counts["ERROR"] != expected_errors or len(error_lines) != expected_errors:
        reasons.append("expected {} UVM errors, found summary={} diagnostics={}".format(
            expected_errors, counts["ERROR"], len(error_lines)))
    allowed_errors = set()
    if expected_injection:
        if not (len(markers) == 1 and re.fullmatch(
                r"\s*\(observed exactly 3 TBI-1 violations\)\s*", markers[0][1])):
            reasons.append("missing exact three-violation injection oracle marker")
        for line in error_lines:
            if EXPECTED_INJECTION_DIAGNOSTIC.search(line):
                allowed_errors.add(line.strip())
            else:
                reasons.append("unexpected error category in injection test")
    elif expected_timeout:
        marker_valid = len(markers) == 1 and re.fullmatch(EXPECTED_TIMEOUT_SUFFIX, markers[0][1])
        if not marker_valid:
            reasons.append("missing exact one-timeout/no-DATA-launch oracle marker")
        for line in error_lines:
            if EXPECTED_TIMEOUT_DIAGNOSTIC.search(line):
                allowed_errors.add(line.strip())
            else:
                reasons.append("unexpected error category in exhaustion test")
        if marker_valid:
            for line in output.splitlines():
                if EXPECTED_TIMEOUT_MARKER.fullmatch(line):
                    allowed_errors.add(line.strip())

    for line in output.splitlines():
        if ACCOUNTING_FAILURE.search(line) and line.strip() not in allowed_errors:
            reasons.append("accounting diagnostic: " + line.strip())
    tbi_counts = re.findall(r"\bTBI-([1-6])\s+Violations\s*:\s*(\d+)", output, re.IGNORECASE)
    for invariant, count in tbi_counts:
        expected_count = EXPECTED_TBI1_ERRORS if expected_injection and invariant == "1" else 0
        if int(count) != expected_count:
            reasons.append("unexpected TBI-{} violation counter: {}".format(invariant, count))
    residuals = re.findall(r"\bTBI-4\s+Residual\s*:\s*(-?\d+)", output, re.IGNORECASE)
    for residual in residuals:
        if int(residual) != 0:
            reasons.append("nonzero TBI-4 conservation residual: " + residual)
    if expected_timeout:
        # These are the monitor's actual scored counters; TBI-5 is deliberately
        # not scored by that monitor. TBI-4 is its signed accounting residual.
        for invariant in ("1", "2", "3", "6"):
            if sum(item == invariant for item, _ in tbi_counts) != 1:
                reasons.append("missing or repeated TBI-{} monitor counter".format(invariant))
        if len(residuals) != 1:
            reasons.append("missing or repeated TBI-4 conservation residual")

    return {
        "status": ("EXPECTED_INJECTION_PASS" if expected_injection else
                   "EXPECTED_TIMEOUT_PASS" if expected_timeout else "PASS")
                  if not reasons else "FAIL",
        "uvm_errors": counts["ERROR"],
        "uvm_fatals": counts["FATAL"],
        "reasons": list(dict.fromkeys(reasons)),
    }


def run_suite(simulator, tests, iterations, seed_start, output_dir, timeout):
    """Execute every requested case, retaining raw logs and a run summary."""
    if not simulator or iterations < 1 or seed_start < 1 or timeout <= 0:
        raise ValueError("simulator, positive iterations, seeds, and timeout are required")
    if any(arg.startswith("+ntb_random_seed") for arg in simulator):
        raise ValueError("the runner owns seed arguments; remove simulator seed options")
    if seed_start + iterations - 1 > 2147483647:
        raise ValueError("explicit VCS seeds must fit a positive signed 32-bit integer")
    if not tests or len(set(tests)) != len(tests) or not set(tests) <= set(TESTS):
        raise ValueError("select distinct, known credit tests")

    stamp = datetime.now(timezone.utc).strftime("run_%Y%m%dT%H%M%S_%fZ")
    destination = Path(output_dir).resolve() / stamp
    destination.mkdir(parents=True, exist_ok=False)
    results = []
    for iteration in range(iterations):
        seed = seed_start + iteration
        for test in tests:
            name = "{}_seed_{}".format(test, seed)
            log = destination / (name + ".log")
            console = destination / (name + ".console.log")
            command = list(simulator) + [
                "+UVM_TESTNAME=" + test, "+CREDIT_MODE",
                "+ntb_random_seed={}".format(seed),
                "-l", str(log), "-cm_name", name,
            ]
            timed_out = False
            with console.open("w", encoding="utf-8") as stream:
                try:
                    completed = subprocess.run(command, stdout=stream,
                                               stderr=subprocess.STDOUT, timeout=timeout)
                    returncode = completed.returncode
                except subprocess.TimeoutExpired:
                    timed_out, returncode = True, -1
                except OSError as error:
                    stream.write("Runner could not start simulator: {}\n".format(error))
                    returncode = -1
            # Preserve both raw channels and assess console-only diagnostics as
            # well as native -l output. Their mirrored lines count only once.
            source = log if log.is_file() and log.stat().st_size else console
            output = source.read_text(encoding="utf-8", errors="replace")
            if source != console:
                output = merge_outputs(
                    output, console.read_text(encoding="utf-8", errors="replace"))
            outcome = assess_output(test, output, returncode, timed_out)
            outcome.update(test=test, iteration=iteration + 1, seed=seed,
                           returncode=returncode, timed_out=timed_out,
                           log=str(source), console=str(console), command=command)
            results.append(outcome)
            print("{} seed={} {}{}".format(
                test, seed, outcome["status"],
                ": " + "; ".join(outcome["reasons"]) if outcome["reasons"] else ""), flush=True)

    failures = sum(row["status"] == "FAIL" for row in results)
    summary = {
        "classification": "simulator runner output; not coverage or paper evidence by itself",
        "simulator_command": list(simulator), "tests": list(tests),
        "iterations": iterations, "seed_start": seed_start,
        "runs": len(results), "failures": failures,
        "expected_injection_passes": sum(
            row["status"] == "EXPECTED_INJECTION_PASS" for row in results),
        "expected_timeout_passes": sum(
            row["status"] == "EXPECTED_TIMEOUT_PASS" for row in results),
        "results": results,
    }
    (destination / "summary.json").write_text(json.dumps(summary, indent=2) + "\n",
                                               encoding="utf-8")
    with (destination / "summary.csv").open("w", newline="", encoding="utf-8") as stream:
        fields = ("test", "iteration", "seed", "status", "returncode", "timed_out",
                  "uvm_errors", "uvm_fatals", "log", "reasons")
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for row in results:
            writer.writerow(dict(row, reasons="; ".join(row["reasons"])))
    print("Credit runner: {} runs, {} failures; logs: {}".format(
        len(results), failures, destination), flush=True)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim-command", default="./simv",
                        help="simulator executable and options, split without a shell")
    parser.add_argument("--tests", nargs="+", choices=TESTS, default=list(TESTS))
    parser.add_argument("--iterations", type=int, default=15)
    parser.add_argument("--seed-start", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=300,
                        help="wall-clock limit in seconds for each simulator invocation")
    parser.add_argument("--output-dir", type=Path, default=Path("credit_regression"))
    args = parser.parse_args(argv)
    try:
        summary = run_suite(shlex.split(args.sim_command), args.tests, args.iterations,
                            args.seed_start, args.output_dir, args.timeout)
    except ValueError as error:
        parser.error(str(error))
    return 1 if summary["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
