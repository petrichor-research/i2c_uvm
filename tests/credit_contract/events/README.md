# Event-channel and monitor-accounting unit tests

Run from the repository root:

```bash
python3 tests/credit_contract/events/run_directed.py
```

Verilator compiles functions extracted from the current event-pool and credit-
monitor sources. The actual payload class and protocol types are included.
Minimal plumbing stubs replace UVM infrastructure; tested function bodies are
not translated. The runner prints source hashes and verifies that production
monitor tasks call the tested update functions. Add `--build-dir /tmp/events-test`
to retain the generated harness and executable.

Checks cover independent publisher/consumer snapshots, retained FIFO ordering,
single INIT publication per reset epoch, reset queue cleanup, INIT validation,
and rejection of invalid RETURN updates without accounting-state mutation.
Completion accounting uses the actual transaction complete-image validator,
including DATA/control mixtures in either order; malformed images are rejected
before changing any budget or accepted-byte counters.
RETURN validation uses initialized state, count/depth bounds, and the observed
accepted-byte balance. It does not establish physical FIFO-release causality.
The TBI-4 check uses the signed conservation residual against initialized credit
minus accepted bytes plus applied returns; it does not require the final credit
balance to equal the initial depth. Outstanding accepted bytes are permitted.
Constructed wide counters also check that cumulative totals do not wrap at 32 bits.

The harness also reproduces a checker limitation: a return applied between an
uncredited launch and transaction completion can mask the launch-time deficit.
The monitor's TBI-1 check is a completion-time diagnostic, not an independent
pre-dispatch authorization check. TBI-5 remains a driver-watchdog diagnostic;
this monitor has no request-deadline observation.

These tests do not exercise event wakeups, full UVM scheduling, driver/monitor
integration, mid-run credit-reset recovery, timed liveness, or a wire transport.
One monitor run retains one accounting epoch; recovery after a physical reset
requires restart/reconciliation outside this unit test.
