# Source-derived procedural sampling checks

Run from the repository root:

```sh
python3 tests/credit_contract/sampling/run_directed.py
```

The runner extracts the current task bodies from `src/agent/i2c_monitor.sv`
and `src/agent/i2c_driver.sv`, plus the header decoder from
`src/agent/i2c_transaction.sv`, and inserts them into independent procedural
testbenches, and compiles those harnesses with Icarus Verilog. It prints source
hashes for provenance. Generated files normally live in a temporary directory;
`--build-dir /absolute/path` retains them for inspection.

The mechanical lowering replaces virtual-interface references with ordinary
signals, fixes each timing parameter to 10 ns, removes UVM report macros, and
flattens transaction fields into fixed-size request/capture arrays. Object
creation initializes scalar capture fields; analysis publication snapshots
those fields; event emission increments named event counters. Task control flow,
clock/edge waits, ACK handling, and repeated-START decisions remain the source
implementation. Extracted class tasks are marked `automatic` to preserve class
method lifetime semantics in a procedural module, except the non-reentrant
receive/monitor loops. Those loops use static task storage because Icarus vvp
aborts internally on their nested `disable fork` contexts with automatic
storage. Each loop has at most one active invocation in these harnesses;
reentrant class-method lifetime behavior is not tested.

The checks cover address and data alignment immediately after START for both
passive samplers, and two active write transfers joined by repeated START.
The latter requires exactly two STARTs, one STOP, the bytes `AA,35,AA,CA`, and
one accepted byte per request. Testbench stimulus/observation logic is separate
from the extracted source.

The source-extracted slave receive API is also exercised for idle role/reset
cancellation, a matched two-byte write, unmatched/incomplete addresses, read ACK/NACK
responses, and two API calls separated by repeated START. The source-extracted
monitor loop and independent bus-idle observer are exercised for address/data
NACKs waiting for STOP, repeated-START frame separation, an interrupted ACK,
reset cancellation, incomplete addresses, and post-STOP `tBUF` indication and
cancellation on early activity. The capture arrays are
bounded testbench storage, not a replacement implementation of the byte parser.

These are source-derived procedural simulations, not full UVM elaboration,
VCS regression, wire-level credit-control transport validation, or hardware
measurements. They do not establish the complete credit protocol contract.
