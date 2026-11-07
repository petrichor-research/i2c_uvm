# Source-derived credit-driver accounting checks

```sh
python3 tests/credit_contract/accounting/run_directed.py
```

The runner extracts the current credit-master and credit-slave helper bodies
and the transaction's complete-wire-image validator,
and compiles them in focused procedural Icarus testbenches. Source hashes are
printed. `--build-dir /absolute/path` retains generated harnesses/executables.
The runner reuses reporting-macro removal from the neighboring sampling runner.

Mechanical lowering represents payload and transaction handles as integer
indices into typed-field arrays, substitutes scalar configuration fields, and
replaces persistent event-channel dependencies with explicit FIFO/wakeup
stubs. The helper branches, arithmetic, deadline calculations, role/epoch
checks, ACK-byte qualification, and publication/commit ordering remain source
code. Channel stubs are test dependencies, not validation of the real event
pool. They intentionally allow publication failure to test atomicity.

These checks cover invalid return counts without accounting mutation, positive
balance queue draining, duplicate INIT rejection, one-request stall deadlines
despite partial returns, role/reset cancellation, receiver qualification, and
one consumption per accepted byte, including a partially NACKed write. Metadata
versus wire-tag consistency and impossible ACK counts are rejected. The checks
also cover reset invalidation of delayed return state, invalid/failed
publication leaving counters unchanged, and valid publication committing once.
The CBR's actual `check_phase()` accounting expression is also exercised:
outstanding accepted bytes preserve conservation without requiring drain,
positive and negative residuals retain their sign, injection settings do not
waive an accounting error, and cumulative totals are checked beyond 32 bits.

The dispatch harness also extracts `dispatch_request()`. A bus-call stub
records whether dispatch was reached and supplies controlled ACK results;
it does not model the bus. Invalid later DATA tags, unsupported reads,
control count/shape mismatches, and invalid session conditions must produce
exact `ERROR` with zero accepted bytes and zero bus calls. Valid and partial
NACK paths check reservation commit/rollback. Impossible accepted counts,
including the maximum unsigned count, must disable the session without
unsigned subtraction or guessed credit restoration. Timeout and role aborts
must not fall through to the bus stub.

Icarus does not support output arguments on functions. The non-reentrant
channel-consumer stubs therefore use a module-scoped payload-result slot;
their output argument is mechanically removed from the extracted calls.

This is procedural helper simulation, not full UVM elaboration, VCS regression,
physical FIFO-release causality, or credit-control wire transport validation.
