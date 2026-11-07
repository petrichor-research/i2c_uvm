#!/usr/bin/env python3
"""Test source-extracted event channels and monitor update functions, without UVM."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def extract_function(source, name):
    match = re.search(r"^\s*(?:static\s+)?function\b[^;\n]*\b" + re.escape(name) + r"\s*\(",
                      source, re.MULTILINE)
    if match is None:
        raise ValueError("missing source function: " + name)
    end = re.search(r"\bendfunction\b", source[match.start():])
    if end is None:
        raise ValueError("unterminated source function: " + name)
    return source[match.start():match.start() + end.end()]


def extracted_class(source, functions):
    # Preserve actual class fields and function bodies. Only UVM-dependent tasks
    # and phases are omitted; the template supplies minimal plumbing classes.
    prefix = source[:source.index("  function new(")]
    prefix = re.sub(r"^\s*virtual\s+i2c_if\s+vif;\s*$", "", prefix, flags=re.MULTILINE)
    return prefix + "\n".join(extract_function(source, name) for name in functions) + "\nendclass\n`endif\n"


def checked_run(command, cwd):
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=60)
    if result.returncode:
        print(result.stdout, end="")
        print(result.stderr, end="")
        raise SystemExit("failed: " + " ".join(str(part) for part in command))
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--build-dir", type=Path, help="Retain generated source and executable")
    args = parser.parse_args()
    if shutil.which("verilator") is None:
        parser.error("Verilator is required for source-derived class/handle tests")
    sources = {}
    for relative in ("src/common/i2c_types.sv", "src/common/i2c_credit_types.sv",
                     "src/common/i2c_events.sv", "src/agent/i2c_credit_monitor.sv",
                     "src/agent/i2c_transaction.sv"):
        path = args.source_root / relative
        sources[relative] = path.read_text()
        print("SOURCE " + str(path) + " sha256=" + hashlib.sha256(sources[relative].encode()).hexdigest(), flush=True)
    events = sources["src/common/i2c_events.sv"]
    types = sources["src/common/i2c_credit_types.sv"]
    field_block = types[types.index("class i2c_credit_event_payload"):types.index("`uvm_object_utils_begin")]
    payload_fields = set(re.findall(
        r"^\s*\w+(?:\s+(?:unsigned|signed))?(?:\s*\[[^\]]+\])?\s+(\w+)\s*;",
        field_block, re.MULTILINE))
    snapshot = extract_function(events, "snapshot_credit_payload")
    copied_fields = set(re.findall(r"snapshot\.(\w+)\s*=\s*payload\.\1\s*;", snapshot))
    if copied_fields != payload_fields:
        raise SystemExit("snapshot does not copy all payload fields: " + repr(payload_fields - copied_fields))
    monitor_source = sources["src/agent/i2c_credit_monitor.sv"]
    for task, update in (("monitor_credit_init", "apply_credit_init(init_event)"),
                         ("monitor_credit_returns", "apply_credit_return(return_event)"),
                         ("monitor_accepted_write_bytes", "observe_completed_write(tr)")):
        start = re.search(r"\btask\s+" + task + r"\s*\(", monitor_source)
        if start is None or update not in monitor_source[start.start():monitor_source.index("endtask", start.start())]:
            raise SystemExit("production task is not routed through tested update function: " + task)
    channel = extracted_class(events, (
        "new", "get_global_pool", "get_event", "trigger_event", "valid_credit_payload",
        "publish_credit_init", "publish_credit_return", "snapshot_credit_payload",
        "try_get_credit_init", "try_get_credit_return", "reset_event", "reset_all_events",
    ))
    monitor = extracted_class(monitor_source, (
        "new", "apply_credit_init", "observe_completed_write", "apply_credit_return",
        "check_tbi1", "check_tbi2", "check_tbi6", "check_phase",
    ))
    harness = (HERE / "tb_credit_events.sv").read_text()
    harness = harness.replace("// SOURCE_TYPES", sources["src/common/i2c_types.sv"] + "\n" + types)
    harness = harness.replace("// SOURCE_VALIDATOR", extract_function(
        sources["src/agent/i2c_transaction.sv"], "valid_credit_encoding"))
    harness = harness.replace("// SOURCE_EVENTS", channel).replace("// SOURCE_MONITOR", monitor)
    with tempfile.TemporaryDirectory(prefix="i2c-event-functions-") as temporary:
        build = args.build_dir.resolve() if args.build_dir else Path(temporary)
        build.mkdir(parents=True, exist_ok=True)
        generated = build / "tb_credit_events_generated.sv"
        generated.write_text(harness)
        directory = build / "obj"
        print(checked_run(["verilator", "--version"], args.source_root).strip())
        checked_run(["verilator", "--binary", "--timing", "--Wno-fatal", "--top-module", "tb_credit_events",
                     "--Mdir", str(directory), str(generated)], args.source_root)
        output = checked_run([str(directory / "Vtb_credit_events")], args.source_root)
        print(output, end="")
        if "PASS tb_credit_events" not in output:
            raise SystemExit("missing success marker")


if __name__ == "__main__":
    main()
