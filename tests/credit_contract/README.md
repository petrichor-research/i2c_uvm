# Isolated implementation checks

From the repository root:

```sh
python3 tests/credit_contract/run_all.py
```

Python 3.9 or newer, Icarus Verilog 13.0, Verilator 5.052, and a working C++
toolchain are required. `--report /path/to/report.json` retains commands,
outputs, return codes, and input hashes. A failing group makes the command
fail; this does not invoke the separately configured VCS regression.
With Python 3.12, `pyslang==11.0.0`, and an external official UVM 1.2 tree,
add `--uvm-home /absolute/path/uvm-1.2` to include real-library type/elaboration
and its in-memory missing-member positive control. See `semantic/README.md`.

- `rtl/`: complete behavioral RTL modules driven by directed bus harnesses,
  run with both simulators.
- `sampling/`: source-extracted active driver, target responder, and passive
  capture procedures, with procedural substitutes for UVM plumbing.
- `accounting/`: source-derived CBT/CBR accounting, dispatch, abort, and
  conservation checks.
- `events/`: retained payload snapshots, initialization rules, atomic return
  validation, monitor accounting, and an explicit demonstration of the
  completion-time checker's launch-observation limitation.
- `encoding/`: actual encoder/validator bodies and sequence submission paths.
- `test_regression_runner.py`: fake-process tests of the strict regression
  oracle, expected injection/timeout classification, and explicit seed schedule.
- `semantic/`: optional actual-library type/elaboration; no UVM runtime or DPI linking.

The subdirectory READMEs describe lowering and stub limitations. These checks
do not establish complete UVM elaboration or scheduling, on-wire credit
transport, release-backed recovery, RTL formal proof, or integrated coverage.
No physical FIFO-pop-to-RETURN bridge is connected. Master-mode scenarios
therefore remain within the eight-credit grant, except for the deliberately
blocked ninth request and the designated underflow injection test.
