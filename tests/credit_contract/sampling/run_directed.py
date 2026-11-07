#!/usr/bin/env python3
"""Exercise source-extracted procedural bus helpers, without UVM or VCS."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def extract_task(source: str, name: str) -> str:
    match = re.search(
        rf"^\s*(?:virtual\s+)?task\s+(?:automatic\s+)?{re.escape(name)}\s*\(",
        source,
        re.MULTILINE,
    )
    if match is None:
        raise ValueError(f"Missing source task {name}")
    end = re.search(r"\bendtask\b", source[match.start() :])
    if end is None:
        raise ValueError(f"Unterminated source task {name}")
    task = source[match.start() : match.start() + end.end()]
    return re.sub(r"\btask\s+(?:automatic\s+)?", "task automatic ", task, count=1)


def remove_uvm_reports(source: str) -> str:
    """Remove only reporting macros; preserve each macro's statement position."""
    report = re.compile(r"`uvm_(?:info|warning|error|fatal)\s*\(")
    while match := report.search(source):
        depth = 1
        quoted = False
        escaped = False
        cursor = match.end()
        while cursor < len(source) and depth:
            char = source[cursor]
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            cursor += 1
        if depth:
            raise ValueError("Unterminated UVM report macro")
        source = source[: match.start()] + ";" + source[cursor:]
    return source


def lower_helpers(source: str, *, slave: bool = False) -> str:
    source = remove_uvm_reports(source)
    source = source.replace("vif.scl_drive", "slave_scl_drive" if slave else "scl_drive")
    source = source.replace("vif.sda_drive", "slave_sda_drive" if slave else "sda_drive")
    source = source.replace("vif.scl", "scl").replace("vif.sda", "sda")
    for field, value in (("t_low_ns", 10), ("t_high_ns", 10), ("t_buf_ns", 10)):
        source = source.replace(f"cfg.{field}", str(value))
    source = source.replace("i2c_event_pool::reset_epoch", "reset_epoch")
    return source.replace("i2c_status_e", "integer")


def lower_transfer(source: str) -> str:
    """Flatten the transaction object's fields, not the transfer control flow."""
    source = lower_helpers(source)
    source = source.replace("i2c_transaction tr", "input integer request_index")
    source = source.replace("tr.data.size()", "request_length[request_index]")
    source = re.sub(
        r"foreach\s*\(\s*tr\.data\[(\w+)\]\s*\)",
        r"for (integer \1 = 0; \1 < request_length[request_index]; \1 = \1 + 1)",
        source,
    )
    fields = {
        "accepted_data_bytes": "request_accepted",
        "repeated_start": "request_restart",
        "nack_received": "request_nack",
        "direction": "request_direction",
        "status": "request_status",
        "addr": "request_addr",
        "data": "request_data",
    }
    for field, target in fields.items():
        source = re.sub(rf"\btr\.{field}\b", f"{target}[request_index]", source)
    if re.search(r"\btr\.", source):
        raise ValueError("Transfer task uses an unhandled transaction field")
    return source


def flatten_capture(source: str, name: str) -> str:
    """Lower one handle's storage while retaining its byte/ACK control flow."""
    escaped = re.escape(name)
    source = re.sub(rf"\b{name}\s*=\s*i2c_transaction::type_id::create\([^;]+;", "reset_capture();", source)
    source = re.sub(rf"\bi2c_transaction\s+{escaped}\s*;", "", source)
    source = re.sub(rf"\b{escaped}\.data\s*=\s*new\[0\]\s*;", "captured_length = 0;", source)
    source = re.sub(
        rf"\b{escaped}\.data\s*=\s*new\[{escaped}\.data\.size\(\)\s*\+\s*1\]\s*\({escaped}\.data\)\s*;",
        "captured_length = captured_length + 1;",
        source,
    )
    source = source.replace(f"{name}.data.size()", "captured_length")
    source = source.replace(f"{name}.decode_credit_header()", "decode_capture_header()")
    for field in (
        "accepted_data_bytes", "repeated_start", "nack_received", "direction",
        "status", "addr_mode", "addr", "data", "frame_type", "credit_count",
        "is_credit_init", "is_credit_return",
    ):
        source = re.sub(rf"\b{escaped}\.{field}\b", f"captured_{field}", source)
    if re.search(rf"\b{escaped}\.", source):
        raise ValueError(f"Capture task uses an unhandled {name} field")
    return source


def lower_capture_task(source: str, *, slave: bool) -> str:
    source = lower_helpers(source, slave=slave)
    # Icarus vvp aborts internally on disable-fork in an automatic task's
    # nested contexts. These harnesses invoke each receive loop non-reentrantly,
    # so static task storage leaves the tested control flow unchanged.
    source = source.replace("task automatic ", "task ", 1)
    source = source.replace("i2c_event_pool::reset_epoch", "reset_epoch")
    source = source.replace("cfg.is_master", "role_is_master")
    source = source.replace("cfg.slave_addr", "listen_address")
    source = source.replace("i2c_direction_e'", "")
    if slave:
        source = source.replace("output i2c_transaction tr", "output bit tr")
        source = flatten_capture(source, "captured_tr")
        source = source.replace("tr = null;", "tr = 0;")
        source = source.replace("tr = captured_tr;", "tr = 1;")
    else:
        source = flatten_capture(source, "tr")
        source = source.replace("ap.write(tr)", "capture_publish()")
        source = re.sub(
            r"i2c_event_pool::trigger_event\(i2c_event_pool::(\w+)(?:,\s*tr)?\)",
            r"record_event(\1)",
            source,
        )
    return source


def decode_capture_function(transaction: str) -> str:
    match = re.search(r"\bfunction\s+void\s+decode_credit_header\s*\(\s*\)\s*;", transaction)
    if match is None:
        raise ValueError("Missing transaction decode_credit_header function")
    end = re.search(r"\bendfunction\b", transaction[match.start() :])
    if end is None:
        raise ValueError("Unterminated transaction decode_credit_header function")
    source = transaction[match.start() : match.start() + end.end()]
    source = source.replace("function void decode_credit_header", "function automatic void decode_capture_header")
    source = source.replace("data.size()", "captured_length").replace("i2c_credit_frame_e'", "")
    for field in ("data", "frame_type", "credit_count", "is_credit_init", "is_credit_return"):
        source = re.sub(rf"\b{field}\b", f"captured_{field}", source)
    return source


def harnesses(driver: str, monitor: str, transaction: str) -> dict[str, str]:
    samplers = "\n\n".join(
        lower_helpers(extract_task(monitor, name)) for name in ("sample_byte", "sample_bit")
    )
    samplers += "\n\n" + lower_helpers(extract_task(driver, "slave_read_byte"), slave=True)
    active_names = (
        "wait_half_period", "send_start", "send_repeated_start", "send_stop",
        "send_byte", "wait_ack", "read_byte", "send_ack", "send_nack",
    )
    active = "\n\n".join(lower_helpers(extract_task(driver, name)) for name in active_names)
    active += "\n\n" + lower_transfer(extract_task(driver, "drive_transfer"))
    slave = "\n\n".join(
        lower_helpers(extract_task(driver, name), slave=True)
        for name in ("slave_read_byte", "slave_send_byte", "slave_send_ack_result", "slave_sample_ack")
    )
    slave += "\n\n" + lower_capture_task(extract_task(driver, "wait_for_request_result"), slave=True)
    passive = "\n\n".join(
        lower_helpers(extract_task(monitor, name)) for name in ("sample_byte", "sample_bit")
    )
    passive += "\n\n" + "\n\n".join(
        lower_capture_task(extract_task(monitor, name), slave=False)
        for name in ("monitor_transactions", "monitor_bus_idle")
    )
    common = (HERE / "bus_capture_common.svh").read_text()
    decode = decode_capture_function(transaction)
    generated = {
        "edge_sampling": (HERE / "tb_edge_sampling.sv").read_text().replace("// SOURCE_TASKS", samplers),
        "combined_transfer": (HERE / "tb_combined_transfer.sv").read_text().replace("// SOURCE_TASKS", active),
        "slave_receive": (HERE / "tb_slave_receive.sv").read_text().replace("// SOURCE_TASKS", slave),
        "monitor_frames": (HERE / "tb_monitor_frames.sv").read_text().replace("// SOURCE_TASKS", passive),
    }
    return {
        name: source.replace("// CAPTURE_COMMON", common).replace("// SOURCE_DECODE", decode)
        for name, source in generated.items()
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=REPO)
    parser.add_argument("--build-dir", type=Path, help="Retain generated harnesses and executables here")
    args = parser.parse_args()
    for tool in ("iverilog", "vvp"):
        if shutil.which(tool) is None:
            parser.error(f"Required tool not found: {tool}")
    driver_path = args.source_root / "src/agent/i2c_driver.sv"
    monitor_path = args.source_root / "src/agent/i2c_monitor.sv"
    transaction_path = args.source_root / "src/agent/i2c_transaction.sv"
    driver = driver_path.read_text()
    monitor = monitor_path.read_text()
    transaction = transaction_path.read_text()
    for path, source in ((driver_path, driver), (monitor_path, monitor), (transaction_path, transaction)):
        print(f"SOURCE {path} sha256={hashlib.sha256(source.encode()).hexdigest()}", flush=True)
    generated = harnesses(driver, monitor, transaction)
    with tempfile.TemporaryDirectory(prefix="i2c_sampling_") as temporary:
        build = args.build_dir or Path(temporary)
        build.mkdir(parents=True, exist_ok=True)
        failures = 0
        for name, source in generated.items():
            harness = build / f"{name}.sv"
            executable = build / f"{name}.vvp"
            harness.write_text(source)
            print(f"TEST {name}", flush=True)
            result = subprocess.run(
                ["iverilog", "-g2012", "-s", "tb", "-o", str(executable), str(harness)],
                check=False,
            )
            if result.returncode == 0:
                result = subprocess.run(["vvp", str(executable)], check=False, timeout=15)
            failures += result.returncode != 0
        print(f"RESULT {len(generated) - failures}/{len(generated)} source-derived tests passed", flush=True)
        return int(failures != 0)


if __name__ == "__main__":
    raise SystemExit(main())
