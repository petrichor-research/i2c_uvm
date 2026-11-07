#!/usr/bin/env python3
"""Exercise the retained credit encoder and sequence grant ordering with Icarus."""

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
HELPERS = runpy.run_path(str(HERE.parent / "sampling/run_directed.py"))
REMOVE_REPORTS = HELPERS["remove_uvm_reports"]


def extract(source: str, name: str, kind: str) -> str:
    match = re.search(
        rf"^\s*{kind}\s+(?:(?:automatic|bit|void)\s+)*{re.escape(name)}\s*\(",
        source, re.MULTILINE,
    )
    if match is None:
        raise ValueError(f"Missing {kind} {name}")
    end = re.search(rf"\bend{kind}\b", source[match.start():])
    if end is None:
        raise ValueError(f"Unterminated {kind} {name}")
    return source[match.start():match.start() + end.end()]


def class_source(source: str, name: str) -> str:
    match = re.search(rf"\bclass\s+{re.escape(name)}\b.*?\bendclass\b", source, re.DOTALL)
    if match is None:
        raise ValueError(f"Missing class {name}")
    return match.group(0)


def lower_encoder(source: str) -> str:
    source = REMOVE_REPORTS(source).replace("i2c_credit_frame_e'", "")
    # Icarus cannot elaborate a packed part-select directly on a dynamic-array
    # element. These read-only slices are identical unsigned shift/mask reads.
    source = re.sub(
        r"data\[([^\]]+)\]\[I2C_CREDIT_FRAME_TYPE_MSB:I2C_CREDIT_FRAME_TYPE_LSB\]",
        r"((data[\1] >> 6) & 3)", source,
    )
    source = re.sub(
        r"data\[([^\]]+)\]\[I2C_CREDIT_PAYLOAD_MSB:I2C_CREDIT_PAYLOAD_LSB\]",
        r"(data[\1] & 63)", source,
    )
    return source.replace("function ", "function automatic ", 1)


def lower_sequence(source: str, name: str) -> str:
    source = REMOVE_REPORTS(source)
    source = re.sub(r"\bi2c_transaction\s+tr\s*;", "", source)
    source = re.sub(r"\btr\s*=\s*i2c_transaction::type_id::create\([^;]+;", "reset_item();", source)
    source = source.replace("super.pre_body();", ";")
    source = source.replace("tr.encode_credit_header()", "encode_credit_header()")
    for field in (
        "accepted_data_bytes", "is_credit_init", "is_credit_return", "credit_count",
        "frame_type", "direction", "addr_mode", "frame_id", "addr", "data",
    ):
        source = re.sub(rf"\btr\.{field}\b", "item_frame_id" if field == "frame_id" else field, source)
    source = source.replace("start_item(tr)", "start_item(0)").replace("finish_item(tr)", "finish_item(0)")
    source = source.replace("cfg.cbr_depth", "cfg_depth").replace("cfg.cbr_pipe_delay", "cfg_pipe_delay")
    source = re.sub(r"\btask\s+\w+\s*\(", f"task automatic {name}(", source, count=1)
    if re.search(r"\btr\b|\bcfg\.", source):
        raise ValueError(f"Unhandled sequence dependency in {name}")
    return source


def generate(sources: dict[str, str]) -> dict[str, str]:
    transaction = sources["src/agent/i2c_transaction.sv"]
    methods = "\n\n".join(lower_encoder(extract(transaction, name, "function")) for name in (
        "encode_credit_header", "valid_credit_encoding", "decode_credit_header",
    ))
    base = sources["src/seq/i2c_credit_base_sequence.sv"]
    burst = sources["src/seq/i2c_credit_burst_sequence.sv"]
    error = sources["src/seq/i2c_credit_error_sequence.sv"]
    sequence_methods = [lower_sequence(extract(base, "send_data_frame", "task"), "send_data_frame")]
    for source, cls, method, target in (
        (base, "i2c_credit_init_sequence", "body", "run_init"),
        (base, "i2c_credit_data_sequence", "body", "run_data"),
        (burst, "i2c_credit_burst_sequence", "body", "run_burst"),
        (burst, "i2c_credit_exhaustion_sequence", "body", "run_exhaustion"),
        (error, "i2c_credit_error_sequence", "run_send_without_credit", "run_error_data"),
        (error, "i2c_credit_error_sequence", "run_phantom_credit", "run_phantom"),
        (error, "i2c_credit_error_sequence", "run_init_glitch", "run_glitch_data"),
    ):
        sequence_methods.append(lower_sequence(extract(class_source(source, cls), method, "task"), target))
    common = (HERE / "encoding_common.svh").read_text()
    return {
        "encoding": (HERE / "tb_encoding.sv").read_text().replace("// COMMON", common).replace("// SOURCE_METHODS", methods),
        "sequence_encoding": (HERE / "tb_sequence_encoding.sv").read_text().replace("// COMMON", common).replace(
            "// SOURCE_METHODS", methods + "\n\n" + "\n\n".join(sequence_methods)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=REPO)
    parser.add_argument("--build-dir", type=Path)
    args = parser.parse_args()
    for tool in ("iverilog", "vvp"):
        if shutil.which(tool) is None:
            parser.error(f"Required tool not found: {tool}")
    paths = (
        "src/agent/i2c_transaction.sv", "src/seq/i2c_credit_base_sequence.sv",
        "src/seq/i2c_credit_burst_sequence.sv", "src/seq/i2c_credit_error_sequence.sv",
    )
    sources = {path: (args.source_root / path).read_text() for path in paths}
    for path, source in sources.items():
        print(f"SOURCE {path} sha256={hashlib.sha256(source.encode()).hexdigest()}", flush=True)
    generated = generate(sources)
    with tempfile.TemporaryDirectory(prefix="i2c_encoding_") as temporary:
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
