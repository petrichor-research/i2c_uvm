# I2C Verification Test Plan

## 1. Introduction

This document defines verification objectives and implemented test infrastructure for the I2C (Inter-Integrated Circuit) UVM Verification IP (VIP) hosted in this workspace. It targets features described by the NXP I2C-bus specification (UM10204); the presence of a test or covergroup is not a blanket protocol-conformance result. Two manuscripts use the shared source tree:

- **Dual-role bus ownership**: single-agent role-flip and bus-ownership objectives.
- **Receiver-capacity verification** (IEEE Access revision, 2026): six Transmit-Budget Invariants (TBIs) evaluated in an executable accounting model, with a source-level UVM mapping and explicit implementation gaps.

The project repository is <https://github.com/tobliao/i2c_uvm>. The credit manuscript identifies a separate revision-specific reproduction archive; a repository URL alone does not establish that every local manuscript artifact is publicly available.

### 1.1 Scope

The implementation and test objectives cover:

- **Roles**: Single Master, Single Slave, dual-role role-flip via the bus ownership invariant set.
- **Speeds**:
  - Standard-mode (Sm): 100 kbit/s.
  - Fast-mode (Fm): 400 kbit/s.
  - Fast-mode Plus (Fm+): 1 Mbit/s.
- **Addressing**: 7-bit and 10-bit addressing.
- **Protocol features**: Clock Stretching, Repeated Start, ACK/NACK handling, General Call.
- **Dual-role bus ownership extension**: BOI-1..BOI-N enforced by the dual-role monitor (see the dual-role manuscript at `paper/deterministic_dual_role_i2c_verification/access.tex`).
- **Credit-based flow control extension**: CBT reservation and ACK/NACK accounting, retained event-mode INIT/RETURN delivery, and completion-time shadow-counter diagnostics. The reference contract defines positive pre-dispatch authorization, matched/bounded capacity, initialization ordering, conservation, blocked-request resolution, and release-causal returns. The current integration does not independently enforce all six obligations; Section 6 separates the model from implementation checks. Sources: `src/agent/i2c_credit_*.sv`, `src/common/i2c_events.sv`, and `rtl/i2c_credit_slave.sv`.

### 1.2 Out of Scope (Future Work)

The following features are designed for, or proposed for, future revisions but are **not** currently verified in the active test suite:

- **Multi-Master Arbitration**: Logic for arbitration loss and back-off.
- **High-Speed Mode (Hs-mode)**: 3.4 Mbit/s signaling and master code logic.
- **Ultra Fast-mode (UFm)**: Unidirectional 5 Mbit/s.
- **Multi-receiver credit pools**: Per-endpoint budgets for multiple targets. The current credit topology contains one CBT/CBR pair and one selected RTL target.
- **I3C dynamic address assignment**: ENTDAA / SETDASA / RSTDAA flows for an I3C extension of the credit framework.
- **Integrated credit proof and transport**: No RTL formal proof, full VCS credit regression, physical FIFO-pop-to-RETURN bridge, independent launch-budget observation, per-credit latency monitor, return-message identity check, or wire-level INIT/RETURN exchange is established.

---

## 2. Verification Strategy

The repository provides a UVM-based constrained-random environment and focused executable reference/implementation checks. The revised credit manuscript's numerical results come from its untimed Python model, not an integrated UVM run.

- **Stimulus**: UVM Sequences driving the Agent (acting as Master, Slave, or both via the dual-role role-flip). Credit-mode stimulus is driven by `i2c_credit_{base,burst,error}_sequence.sv`.
- **Checking**: The base bus monitor samples I2C traffic and publishes `TRANS_COMPLETE`. The credit monitor consumes these completion notifications plus separate retained INIT/RETURN payload queues. Event pulses are wake-up hints, not payload storage. The credit monitor does not reconstruct a complete wire-level credit protocol or observe physical releases. Its analysis port is not connected to the coverage/scoreboard fan-out.
- **Encoding units**: The wire scaffold carries a two-bit type tag and six payload bits per DATA byte (0--63); control counts fit 1--63. Retained event counts are validated independently over 1--256. A byte-wide physical FIFO entry is the accounting unit, not a promise of eight user-payload bits under this encoding.
- **Coverage**:
  - **Functional Coverage**: Explicit covergroups for protocol states, address ranges, transaction types, credit frame types, credit FSM states, and credit FSM transitions.
  - **Code Coverage**: Line, Toggle, FSM, Condition, and Branch coverage enabled in simulation.
- **Mode selection**: `+CREDIT_MODE` selects the credit-aware RTL bus contribution; `cfg.credit_mode_enable = 1` selects credit components in the UVM agent. These are distinct controls and credit targets set both through their test/command configuration. Credit mode disables the auxiliary RTL controller's bus contribution.

---

## 3. Test Cases

### 3.1 Basic Transport Tests (Sanity)

| Test ID | Test Name | Description | Priority | Coverage Goal |
| :--- | :--- | :--- | :--- | :--- |
| **TP_001** | `sanity_wr_7bit` | Master writes 1 byte to a 7-bit Slave. Verify ACK and Stop. | **P0** | Basic Write, Addr Low Range |
| **TP_002** | `sanity_rd_7bit` | Master reads 1 byte from a 7-bit Slave. Verify ACK and Stop. | **P0** | Basic Read |
| **TP_003** | `sanity_wr_10bit` | Master writes 1 byte to a 10-bit Slave (2-byte address sequence). | **P1** | 10-bit Address |
| **TP_004** | `sanity_rd_10bit` | Master reads 1 byte from a 10-bit Slave (Write Address -> Sr -> Read). | **P1** | 10-bit Read path |

### 3.2 Transaction Types

| Test ID | Test Name | Description | Priority | Coverage Goal |
| :--- | :--- | :--- | :--- | :--- |
| **TP_101** | `burst_write` | Master writes N bytes (random 2-128) in a single transaction. | **P1** | Burst Write, Size Bins |
| **TP_102** | `burst_read` | Master reads N bytes (random 2-128) in a single transaction. | **P1** | Burst Read |
| **TP_103** | `repeated_start` | Write transfer followed immediately by a Repeated Start (Sr) and another transfer. | **P1** | Repeated Start |
| **TP_104** | `mixed_transfers` | Random mix of Writes, Reads, and Repeated Starts without releasing the bus. | **P2** | Stress Test, Cross Coverage |

### 3.3 Protocol Features & Corner Cases

| Test ID | Test Name | Description | Priority | Coverage Goal |
| :--- | :--- | :--- | :--- | :--- |
| **TP_201** | `clk_stretch_slave` | Slave holds SCL Low before ACK/Data. Master must wait indefinitely. | **P1** | Clock Synchronization |
| **TP_202** | `nack_addr` | Master addresses a non-existent Slave. Verify NACK on address byte and Stop generation. | **P1** | Address NACK, Status Bins |
| **TP_203** | `nack_data` | Slave NACKs a data byte (e.g., buffer full). Master must Abort or Stop. | **P2** | Data NACK flow |
| **TP_204** | `gen_call_req` | Master sends General Call address (`0000000`). Verify all capable slaves ACK. | **P2** | General Call Bin |
| **TP_205** | `zero_byte_seq` | Master sends Address + R/W bit, gets ACK, then immediately Stops. | **P3** | Empty Payload Bin |

### 3.4 Timing & Configuration

| Test ID | Test Name | Description | Priority | Coverage Goal |
| :--- | :--- | :--- | :--- | :--- |
| **TP_301** | `speed_change` | Configure bus to Fm (400kHz) and Fm+ (1MHz). Verify timing parameters (tLOW, tHIGH). | **P2** | Speed Config Bins |
| **TP_302** | `min_timings` | Drive SCL/SDA with minimum allowed setup/hold times. Verify robustness. | **P3** | Timing Margin |

### 3.5 Credit-Based Flow Control Tests

These are implementation scenarios, not reported credit-regression results. The physical target is the behavioral eight-entry FIFO in `rtl/i2c_credit_slave.sv`, with matched advertised depth `D=P=8`. Its `PIPE_DELAY` parameter does not implement autonomous physical release or RETURN delivery. CBR pipeline completion is a separate behavioral testbench mechanism and is not physical-pop evidence. `make regr_credit` configures six scenarios with 15 explicit seeds by default (90 scheduled invocations); VCS is unavailable in the current workspace and this schedule has not been executed as a manuscript experiment.

| Test ID | Test Name | Description | Primary TBIs | Priority | Coverage Goal |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **TP_501** | `credit_sanity` | Event-mode initialization and four one-byte writes within the initial eight-credit budget. No automatic return or final full-budget result is assumed. | Budget/init accounting | **P0** | ACK-qualified accounting |
| **TP_502** | `credit_exhaustion` | Accept eight writes, then submit one ninth request. Require exactly one expected CBT watchdog error, TIMEOUT/zero-accept response, no SCL/SDA transitions during that request, unchanged bus-transaction total, and zero remaining budget. No recovery is claimed. | Dispatch/stall-abort oracle | **P0** | Exhaustion and no-fall-through timeout |
| **TP_503** | `credit_burst` | Two to four groups of one-byte writes with group size 1--4 and total `burst_count*burst_size<=8`. Check exact accepted/bus counts and outstanding budget; no RETURN or measured burst sweep is claimed. | Budget bounds | **P1** | Grouping within one grant |
| **TP_504** | `credit_error` | The selected scenario bypasses dispatch gating for three attempts beyond the initial budget. Require the exact three-diagnostic TBI-1 oracle and reject all unrelated errors; phantom-return scenarios are not selected by this test. | Completion-time deficit sensitivity | **P1** | Directed expected-injection oracle |
| **TP_505** | `credit_dual_role` | Four master writes, a quiet slave-listen interval, cancellation on return to master, and three resumed writes. Bounded waits and unchanged receive/return accounting are checked. No peer controller or slave-role traffic is generated. | Logical role/configuration interaction | **P2** | Two harness role commits and master resume |
| **TP_506** | `credit_random` | Choose 3--8 total writes, then consume that finite scheduling budget with random plain/burst groupings. Fix `D=P=8`; bounded knob randomization does not establish that every knob affects the endpoint or that its full range is covered. | Configuration/grouping objectives | **P2** | Within-budget variation, not a coverage result |

All scenarios have bounded sequence waits and explicit no-RETURN accounting oracles for accepted bytes, completed bus transactions, remaining budget, stall episodes, and monitor diagnostics. Normal sanity/burst/random/role-switch schedules never exceed the initial grant. The strict runner requires a passing test marker and consistent UVM severity summaries. Missing markers, nonzero simulator exits, unexpected diagnostics, and wall-clock timeouts fail the aggregate run. The error test is an expected-injection pass only when exactly three TBI-1 diagnostics and its oracle marker match. Exhaustion uses a report catcher that counts one exact CBT watchdog error without suppressing or demoting it; require UVM_ERROR=1, UVM_FATAL=0, zero monitor TBI violations, and `TEST STATUS: PASSED (observed exactly 1 expected TBI-5 timeout; no DATA launch)`. This diagnostic abort is not recovery. Final credit need not equal the initial budget while accepted bytes remain resident; physical conservation additionally requires occupancy, reservation, and release observations that the current integration does not supply.

---

## 4. Coverage Model (Implemented)

The `i2c_coverage` class in `src/env/i2c_coverage.sv` implements the following covergroups.

### 4.1 `i2c_protocol_cg`

- **Address 7-bit**: Bins for `0` (General Call), Low `[1:15]`, Mid `[16:111]`, High `[112:126]`, Max `127`.
- **Direction**: `Write`, `Read`.
- **Status**: `OK`, `ADDR_NACK`, `DATA_NACK`.
- **Payload Size**: `1`, `Small Burst [2:8]`, `Large Burst [9:128]`.
- **Repeated Start**: Toggle coverage for Stop vs Repeated Start.
- **Cross Coverage**:
  - Direction x Status
  - Direction x Size
  - Direction x Repeated Start

### 4.2 `i2c_config_cg`

- **Speed Modes**: `Standard`, `Fast`, `Fast+`.

### 4.3 `credit_protocol_cg` (credit-mode only)

Declared in `src/env/i2c_coverage.sv` and sampled from transaction metadata when `cfg.credit_mode_enable = 1`. The credit monitor's analysis port is unconnected, and the base monitor does not publish a complete credit-state trace. These bins are instrumentation declarations, not evidence of credit-state coverage or independent TBI checking.

- **Frame type** (`cp_frame_type`): `data_frame`, `init_frame`, `return_frame`, `status_frame`.
- **Credit FSM state** (`cp_credit_state`): `reset`, `init`, `ready`, `active`, `exhausted`, `error`.
- **Credit counter** (`cp_credit_counter`): `zero`, `low [1:2]`, `mid [3:6]`, `high [7:15]`, `full [16:256]`. `negative [-256:-1]` is an illegal bin, but it can diagnose only the values actually supplied to the covergroup; it does not observe launch authorization.
- **Data size** (`cp_data_size`): `single`, `small [2:4]`, `medium [5:16]`, `large [17:128]`.
- **Cross Coverage**:
  - `cross_frame_state`: frame type x credit state
  - `cross_frame_counter`: frame type x credit counter

### 4.4 `credit_transition_cg` (credit-mode only)

FSM transition bins in `src/env/i2c_coverage.sv` (no achieved coverage percentage is claimed):

- `init_to_ready`: `CREDIT_STATE_INIT => CREDIT_STATE_READY`
- `ready_to_active`: `CREDIT_STATE_READY => CREDIT_STATE_ACTIVE`
- `active_to_exhaust`: `CREDIT_STATE_ACTIVE => CREDIT_STATE_EXHAUSTED`
- `exhaust_to_active`: `CREDIT_STATE_EXHAUSTED => CREDIT_STATE_ACTIVE`
- `active_to_ready`: `CREDIT_STATE_ACTIVE => CREDIT_STATE_READY`

---

## 5. Directory Structure

```text
i2c_uvm/
├── docs/                          # This testplan and protocol notes
├── rtl/
│   ├── i2c_master.sv              # Behavioral Master
│   ├── i2c_slave.sv               # Behavioral Slave (SLAVE_ADDR=0x55)
│   └── i2c_credit_slave.sv        # Behavioral FIFO; no physical-pop/RETURN bridge
├── sim/                           # Makefile and per-run logs
├── src/
│   ├── common/
│   │   ├── i2c_types.sv
│   │   ├── i2c_events.sv
│   │   └── i2c_credit_types.sv    # Credit frame-type enum, FSM state enum, defaults
│   ├── agent/
│   │   ├── i2c_driver.sv          # Base driver (master + slave modes)
│   │   ├── i2c_monitor.sv
│   │   ├── i2c_credit_master_driver.sv  # CBT (credit-gated dispatch)
│   │   ├── i2c_credit_slave_driver.sv   # CBR (pipeline-delayed return)
│   │   ├── i2c_credit_monitor.sv        # Completion-time shadow accounting
│   │   ├── i2c_config.sv          # Config (incl. credit knobs)
│   │   ├── i2c_sequencer.sv
│   │   └── i2c_agent.sv
│   ├── env/
│   │   ├── i2c_env.sv
│   │   ├── i2c_scoreboard.sv
│   │   └── i2c_coverage.sv        # Hosts both base and credit covergroups
│   ├── seq/
│   │   ├── i2c_base_sequence.sv
│   │   ├── i2c_mixed_sequence.sv
│   │   ├── i2c_credit_base_sequence.sv
│   │   ├── i2c_credit_burst_sequence.sv
│   │   └── i2c_credit_error_sequence.sv
│   ├── tests/
│   │   ├── i2c_test_base.sv
│   │   ├── i2c_sanity_test.sv     # ... and the rest of the dual-role suite
│   │   ├── i2c_credit_test_base.sv
│   │   ├── i2c_credit_sanity_test.sv
│   │   ├── i2c_credit_exhaustion_test.sv
│   │   ├── i2c_credit_burst_test.sv
│   │   ├── i2c_credit_error_test.sv
│   │   ├── i2c_credit_dual_role_test.sv
│   │   └── i2c_credit_random_test.sv
│   ├── i2c_pkg.sv
│   ├── i2c_test_pkg.sv
│   └── i2c_if.sv
├── img/seaborn/                   # Figure-generation scripts (matplotlib + seaborn)
└── paper/                         # Manuscript sources (LaTeX, gitignored)
    ├── deterministic_dual_role_i2c_verification/
    └── credit_based_flow_control_verification/
```

---

## 6. TBI Reference

| TBI | Reference-model contract | Current implementation/evidence boundary |
| :--- | :--- | :--- |
| **TBI-1** | Positive credit is reserved before byte launch; ACK commits and NACK rolls back. | CBT dispatch gate and reservation; monitor diagnostic occurs at `TRANS_COMPLETE`, not launch. A return during the transfer can mask a launch-time deficit. |
| **TBI-2** | Matched `D=P`; bounded available credit, physical occupancy, released capacity, and reservation. | Tests match the eight-entry target and counters are bounded. The monitor does not observe all physical/reference state variables. |
| **TBI-3** | Valid initialization precedes reservation, launch, and acceptance. | Retained INIT payload validation and driver dispatch gate; not a wire INIT exchange or reset-recovery proof. |
| **TBI-4** | Conservation `q+c+u+r=P`, with `q=A-F`, `u=F-R`, and `c=P-A+R-r`. | Accepted/returned shadow bookkeeping is partial. A full-budget end condition alone is neither this invariant nor proof of physical conservation. |
| **TBI-5** | Resolve a blocked request by valid return/retry or eligible deadline abort without DATA fall-through. | Driver watchdog diagnostic with an absolute blocked-request deadline; no independent monitor deadline observation or per-credit return timer. The reference model is untimed. |
| **TBI-6** | Aggregate release causality `R<=F<=A`. | RETURN validation uses accepted-byte bounds, not physical releases. No FIFO-pop bridge or return-message identity check exists; duplicates may escape while other capacity remains outstanding. |

The reference-model definitions and retained outputs are in `paper/credit_based_flow_control_verification/evidence/credit_safety_model.py`. Source-level checks in the drivers, event pool, and monitor are narrower than that contract. Logs assist diagnosis within those checks; they do not establish complete independent enforcement of all six TBIs.

---

## 7. Reproduction

The revised manuscript's model results are reproduced separately from implementation regression:

```bash
cd paper/credit_based_flow_control_verification/evidence
python3 -m unittest -v test_credit_safety_model.py
python3 credit_safety_model.py
python3 -m pip install -r requirements-figures.txt
python3 generate_manuscript_figures.py
```

The retained model reports 11 unit tests, 628 reachable states, and 1,636 legal transitions over matched depths one through eight. Its control-traffic calculation is analytical. It does not measure bus time, deadline expiry, or hardware behavior. The figure requirements need Python 3.11 or newer; retained tool-version details and static-check commands are in the evidence README.

For an implementation campaign on a VCS/UVM-capable host:

```bash
cd sim
make regr_credit
make regr_credit CREDIT_ITERATIONS=2 CREDIT_SEED_START=41
```

The default schedule is six scenarios times 15 explicit seeds (`+ntb_random_seed=1` through `15`), not automatic seeds. Configure `CREDIT_ITERATIONS`, `CREDIT_SEED_START`, `CREDIT_TIMEOUT_S` (default 300 seconds per simulator invocation), and `CREDIT_LOG_DIR`. Unique directories under `sim/credit_regression/` retain raw simulator/console logs and CSV/JSON summaries. Single-seed targets are `make run_credit_{sanity,exhaustion,burst,error,dual_role,random}`; `make regr_full` also invokes the credit runner. A scheduled count or a fake-runner unit test is not an executed VCS result. VCS is unavailable in the current workspace, and no 90-run integrated result or coverage percentage is reported.

Focused checks under `tests/credit_contract/{rtl,sampling,events,accounting}/run_directed.py` exercise isolated RTL or selected source-derived methods with documented UVM substitutions. Runner tests use fake processes: `python3 -B -m unittest discover -s tests/credit_contract -p test_regression_runner.py -v`. These are implementation diagnostics, not a replacement for a full UVM build. Legacy plots in `img/seaborn/generate_credit_plots.py` contain labeled synthetic examples and are not manuscript evidence.

The full artifact map (listings, figures, tables) for the credit manuscript is given in the `Code and Data Availability` subsection of `paper/credit_based_flow_control_verification/access.tex` and mirrored in the repository-root [README.md](../README.md). The public repository is <https://github.com/tobliao/i2c_uvm>.
