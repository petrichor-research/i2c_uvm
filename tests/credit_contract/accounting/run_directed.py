#!/usr/bin/env python3
"""Compile focused, source-derived credit-driver helper checks with Icarus."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
REMOVE_REPORTS = runpy.run_path(str(HERE.parent / "sampling/run_directed.py"))["remove_uvm_reports"]


def extract(source: str, name: str, kind: str) -> str:
    pattern = rf"^\s*(?:static\s+)?{kind}\s+(?:(?:automatic|bit|void|int|integer)\s+)*{re.escape(name)}\s*\("
    match = re.search(pattern, source, re.MULTILINE)
    if match is None:
        raise ValueError(f"Missing {kind} {name}")
    end = re.search(rf"\bend{kind}\b", source[match.start() :])
    if end is None:
        raise ValueError(f"Unterminated {kind} {name}")
    return source[match.start() : match.start() + end.end()]


def lower(source: str) -> str:
    """Replace storage/transport dependencies, retaining helper control flow."""
    source = REMOVE_REPORTS(source)
    source = re.sub(r"\bstatic\s+(?=(?:task|function)\b)", "", source)
    source = source.replace("i2c_event_pool::reset_epoch", "reset_epoch")
    source = source.replace("i2c_event_pool::", "channel_")
    source = source.replace("cfg.", "cfg_")
    source = source.replace("uvm_phase phase", "input integer phase")
    source = source.replace("super.check_phase(phase);", ";")
    source = re.sub(r"i2c_credit_event_payload::type_id::create\([^)]*\)", "new_payload()", source)
    source = source.replace("i2c_credit_event_payload", "integer")
    source = source.replace("i2c_transaction", "integer")
    source = source.replace("i2c_status_e", "integer").replace("i2c_credit_state_e", "integer")
    source = source.replace("i2c_credit_frame_e", "integer").replace("uvm_event", "integer")
    source = re.sub(r"\bnull\b", "0", source)
    source = source.replace("tr.valid_credit_encoding()", "transaction_valid_credit_encoding(tr)")
    source = re.sub(r"\b(\w+)\.wait_trigger\(\)", "@(channel_hint)", source)
    for field in ("frame_type", "credit_count", "epoch", "reset_epoch", "physical_release_observed"):
        source = re.sub(rf"\b(\w+)\.{field}\b", rf"payload_{field}[\1]", source)
    source = source.replace("tr.data.size()", "transaction_size[tr]")
    source = source.replace("tr.data[", "transaction_data[tr][")
    for field in ("direction", "status", "accepted_data_bytes", "nack_received", "addr", "frame_type"):
        source = source.replace(f"tr.{field}", f"transaction_{field}[tr]")
    # The frame_type rewrite above is for payload handles; transaction tr is
    # distinguished here because the public receiver helper takes that handle.
    source = source.replace("payload_frame_type[tr]", "transaction_frame_type[tr]")
    # Icarus does not support function output ports. The single non-reentrant
    # channel consumer uses one module-scoped result slot instead.
    source = re.sub(r"channel_try_get_credit_(init|return)\(\s*([^,]+),\s*payload\s*\)",
                    r"channel_try_get_credit_\1(\2)", source)
    source = re.sub(r"^\s*integer payload;\s*$", "", source, flags=re.MULTILINE)
    return source


def lower_validator(transaction: str) -> str:
    source = extract(transaction, "valid_credit_encoding", "function")
    source = source.replace("function bit valid_credit_encoding()", "function automatic bit transaction_valid_credit_encoding(input integer tr)")
    source = source.replace("data.size()", "transaction_size[tr]")
    source = re.sub(r"foreach\s*\(data\[(\w+)\]\)",
                    r"for (integer \1 = 0; \1 < transaction_size[tr]; \1 = \1 + 1)", source)
    source = source.replace("data[", "transaction_data[tr][")
    source = re.sub(r"\bframe_type\b", "transaction_frame_type[tr]", source)
    return re.sub(r"\bcredit_count\b", "transaction_credit_count[tr]", source)


def generate(master: str, slave: str, transaction: str) -> dict[str, str]:
    master_methods = (
        ("receive_credit", "function"), ("update_credit_state", "function"),
        ("apply_credit_return", "function"), ("drain_credit_channels", "function"),
        ("wait_for_credit", "task"),
    )
    slave_methods = (
        ("invalidate_reset_session", "function"),
        ("account_received_transaction", "function"), ("publish_return", "function"),
        ("check_phase", "function"),
    )
    common = (HERE / "channel_stubs.svh").read_text()
    validator = lower_validator(transaction)
    generated = {}
    for name, source, methods in (
        ("cbt_accounting", master, master_methods),
        ("cbr_accounting", slave, slave_methods),
    ):
        bodies = "\n\n".join(lower(extract(source, method, kind)) for method, kind in methods)
        template = (HERE / f"tb_{name}.sv").read_text()
        generated[name] = template.replace("// CHANNEL_STUBS", common).replace("// SOURCE_METHODS", validator + "\n\n" + bodies)
    dispatch_methods = master_methods + (("dispatch_request", "task"),)
    dispatch = "\n\n".join(lower(extract(master, method, kind)) for method, kind in dispatch_methods)
    generated["cbt_dispatch"] = (HERE / "tb_cbt_dispatch.sv").read_text().replace(
        "// CHANNEL_STUBS", common).replace("// SOURCE_METHODS", validator + "\n\n" + dispatch)
    return generated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=REPO)
    parser.add_argument("--build-dir", type=Path, help="Retain generated harnesses and executables")
    args = parser.parse_args()
    for tool in ("iverilog", "vvp"):
        if shutil.which(tool) is None:
            parser.error(f"Required tool not found: {tool}")
    paths = [args.source_root / "src/agent" / name for name in (
        "i2c_credit_master_driver.sv", "i2c_credit_slave_driver.sv", "i2c_transaction.sv",
    )]
    sources = [path.read_text() for path in paths]
    for path, source in zip(paths, sources):
        print(f"SOURCE {path} sha256={hashlib.sha256(source.encode()).hexdigest()}", flush=True)
    generated = generate(*sources)
    with tempfile.TemporaryDirectory(prefix="i2c_accounting_") as temporary:
        build = args.build_dir or Path(temporary)
        build.mkdir(parents=True, exist_ok=True)
        failures = 0
        for name, source in generated.items():
            harness = build / f"{name}.sv"
            executable = build / f"{name}.vvp"
            harness.write_text(source)
            print(f"TEST {name}", flush=True)
            result = subprocess.run(["iverilog", "-g2012", "-s", "tb", "-o", str(executable), str(harness)], check=False)
            if result.returncode == 0:
                result = subprocess.run(["vvp", str(executable)], check=False, timeout=15)
            failures += result.returncode != 0
        print(f"RESULT {len(generated) - failures}/{len(generated)} source-derived tests passed", flush=True)
        return int(failures != 0)


if __name__ == "__main__":
    raise SystemExit(main())
