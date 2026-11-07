# I2C UVM Verification Project

**Repository:** <https://github.com/tobliao/i2c_uvm>

A SystemVerilog UVM verification IP for the I2C protocol, packaged with two reference behavioral RTL models (master and slave) and a credit-aware slave variant. The repository is the source-of-truth for two manuscripts:

1. **Deterministic Dual-Role I2C Verification** (IEEE Access, 2026): bus ownership invariants and mode-flip coverage for a dual-role master/slave VIP.
2. **Receiver-Capacity Verification for I²C Endpoints** (IEEE Access revision, 2026): six Transmit-Budget Invariants, explicit-state evaluation of an executable accounting model, and a UVM source mapping with an explicit implementation boundary.

Both papers reference paths inside this repository in their *Code and Data Availability* sections; the artifact map below mirrors those references so a reviewer can land on either side and navigate to the other.

## Directory Structure

```
i2c_uvm/
├── docs/                       # Testplan and protocol notes
├── rtl/                        # Behavioral RTL models
│   ├── i2c_master.sv
│   ├── i2c_slave.sv
│   └── i2c_credit_slave.sv     # Behavioral FIFO; no physical-pop/RETURN bridge
├── sim/                        # Makefile and per-run logs
├── src/
│   ├── common/                 # Shared types, including i2c_credit_types.sv
│   ├── agent/                  # Driver, monitor, sequencer, and credit variants
│   │   ├── i2c_credit_master_driver.sv   # CBT (credit-gated dispatch)
│   │   ├── i2c_credit_slave_driver.sv    # CBR (pipeline-delayed return)
│   │   └── i2c_credit_monitor.sv         # Completion-time shadow accounting
│   ├── env/                    # Environment, scoreboard, coverage
│   ├── seq/                    # Sequence library, including credit sequences
│   ├── tests/                  # Test library (flat structure)
│   ├── i2c_pkg.sv
│   ├── i2c_test_pkg.sv
│   └── i2c_if.sv
├── img/seaborn/                # Figure-generation scripts (Python + matplotlib)
└── paper/                      # Manuscript sources (LaTeX)
    ├── deterministic_dual_role_i2c_verification/
    └── credit_based_flow_control_verification/
```

## Prerequisites

* Synopsys VCS v2022.06-SP2-1 (or newer) with UVM 1.2 support
* Verdi (optional, for waveform viewing)
* Python 3.9 or newer for the reference model and regression-runner tests
* Python 3.11 or newer for the manuscript's pinned plotting dependency; install `paper/credit_based_flow_control_verification/evidence/requirements-figures.txt`
* Icarus Verilog and Verilator for the focused implementation checks below; PySlang requirements are pinned separately in `evidence/requirements-static.txt`

## Quick Start

```bash
cd sim
make run                  # Sanity test (dual-role VIP)
make run_slave            # Slave-only test
make regr_paper           # 11 scenarios x 15 seeds, dual-role paper regression
make run_credit_sanity    # Single credit-mode smoke test
make regr_credit          # Configured schedule: 6 scenarios x 15 explicit seeds
make regr_full            # Dual-role + credit, full sweep
make cov_rpt              # Generate URG coverage report into cov_report/
```

`+CREDIT_MODE` selects the credit-aware DUT path inside the testbench; the credit-mode `run_*` targets and `regr_credit` set this flag automatically.
The credit schedule is not a reported result: VCS is unavailable in the current workspace, and no integrated 90-run credit campaign is claimed.

## Reproducing the Credit-Based Flow Control Paper

The revised manuscript, *Receiver-Capacity Verification for I²C Endpoints: Transmit-Budget Invariants and Explicit-State Evaluation*, reports an executable accounting model and a UVM source mapping. Its retained evidence consists of 11 unit tests, complete exploration of 628 normalized states and 1,636 legal transitions at matched depths one through eight, static source checks, isolated implementation tests, and an analytical status-read traffic calculation. The matched eight-entry model contains 173 states and 481 transitions. `python3 tests/credit_contract/run_all.py` reruns the directed RTL, extracted-method, and fake-process runner tests; its README describes the optional real-UVM type/elaboration check.

Reproduce the reference-model outputs and all five manuscript figures from the repository root:

```bash
cd paper/credit_based_flow_control_verification/evidence
python3 -m unittest -v test_credit_safety_model.py
python3 credit_safety_model.py
python3 generate_manuscript_figures.py
```

The model writes the state counts and selected invalid-control outcomes to `generated/reference_model_summary.json`, the deterministic accounting traces to `generated/reference_model_trace.csv`, and the analytical traffic values to `generated/analytical_control_fraction.csv`. The figure generator writes vector PDF and PNG assets to `../img/figures/`. The lifecycle and source-architecture diagrams describe model guards and inspected source relationships; the other three figures use the retained JSON/CSV outputs.

Run the static checks from the same `evidence/` directory:

```bash
python3 -m pip install -r requirements-static.txt
python3 sva/check_with_pyslang.py
python3 static/check_changed_sv_syntax.py
iverilog -g2012 -s i2c_credit_slave -o /tmp/i2c_credit_slave.vvp \
  ../../../rtl/i2c_credit_slave.sv
```

The SVA harness establishes syntax and elaboration; the source audit uses inert UVM macro stubs and is syntax-only. Icarus elaborates the isolated RTL endpoint. These checks do not establish a full UVM build, assertion execution, or RTL formal proof. The normalized model has no clock and checks accounting and abort eligibility rather than deadline expiry. INIT and RETURN payloads are retained in separate transmitter and monitor queues in `i2c_event_pool`; event pulses are wake-up hints. The base bus monitor publishes `TRANS_COMPLETE` after decoding traffic. No physical FIFO-release observation is connected to the return path. The paper reports no executed VCS credit regression, measured coverage, random RTL mutation score, or measured bus overhead. See `evidence/README.md` for the retained commands and `evidence/topology_source_manifest.json` for the revision-specific inspected source hashes; later implementation edits require a fresh source audit and package.

### Implementation Regression Runner

`regr_credit` is an implementation workflow, not the source of the revised paper's numbers. Its default schedule is six scenarios with explicit seeds 1 through 15. Configure a replay or smaller schedule with:

```bash
cd sim
make regr_credit CREDIT_ITERATIONS=2 CREDIT_SEED_START=41
make run_credit_sanity CREDIT_SEED_START=41
```

The Python runner requires a passing test-status marker, consistent UVM error/fatal summaries, and no unexpected accounting diagnostics. The directed error-injection scenario must match its exact three-diagnostic TBI-1 oracle. Exhaustion deliberately expects one exact CBT watchdog error, a TIMEOUT response with zero acceptance, and no bus launch; that outcome is not recovery. Both negative cases are classified separately and unrelated errors remain failures. Missing results, simulator failures, and per-run wall-clock timeouts fail the aggregate run even if the last scenario passes. `CREDIT_TIMEOUT_S` defaults to 300 seconds. Raw logs, explicit commands/seeds, and CSV/JSON summaries are retained in a unique run directory under `sim/credit_regression/`, configurable with `CREDIT_LOG_DIR`. These files are not coverage reports.

The physical endpoint and advertised budget are matched at `D=P=8`. Sanity, grouped-burst, random-grouping, and logical role-switch schedules accept at most eight DATA bytes total; their explicit oracles check accepted-byte totals, bus-transaction totals, outstanding credit, and absent returns. Master-mode tests have no physical-release-to-RETURN bridge, so a workload beyond the initial budget cannot demonstrate automatic recovery. Exhaustion fills the initial budget and checks one blocked ninth request. The logical role-switch scenario verifies a quiet listen/cancel interval and resumed master writes; the auxiliary RTL controller is disabled in credit mode, so it does not generate or claim slave-role transfers.

### Focused Implementation Checks

Run from the repository root:

```bash
python3 -B -m unittest discover -s tests/credit_contract -p test_regression_runner.py -v
python3 tests/credit_contract/rtl/run_directed.py
python3 tests/credit_contract/sampling/run_directed.py
python3 tests/credit_contract/events/run_directed.py
python3 tests/credit_contract/accounting/run_directed.py
```

The runner unit tests use fake simulator processes, not VCS. The other harnesses exercise isolated RTL or selected source-derived sampling/accounting functions with documented substitutions for UVM infrastructure. Their scope is recorded alongside each harness. They do not establish full UVM scheduling, independent enforcement of all six TBIs, or physical-release-causal return integration.

## Paper Artifact Map (Credit Paper)

Paths beginning with `paper/credit_based_flow_control_verification/` refer to the revision-specific manuscript and evidence directory. All five figures are generated by `paper/credit_based_flow_control_verification/evidence/generate_manuscript_figures.py`.

| Manuscript artifact | Source-of-truth path or definition |
|---------------------|-----------------------------------|
| Main manuscript | `paper/credit_based_flow_control_verification/access.tex` |
| Fig. 1: I²C topology and UVM hierarchy (`fig:credit_architecture`) | `paper/credit_based_flow_control_verification/evidence/generate_credit_topology.py`; inspected source hashes and connections in `evidence/topology_source_manifest.json` within the manuscript directory; vector asset `img/figures/credit_architecture_diagram.pdf` |
| Fig. 2: control states and event transitions (`fig:credit_lifecycle`) | Model guards in `paper/credit_based_flow_control_verification/evidence/credit_safety_model.py`; asset `img/figures/credit_state_transitions.pdf` within the manuscript directory |
| Fig. 3: reachable states and transitions (`fig:state_exploration`) | `paper/credit_based_flow_control_verification/evidence/generated/reference_model_summary.json`; asset `img/figures/reference_state_exploration.pdf` within the manuscript directory |
| Fig. 4: deterministic accounting traces (`fig:reference_traces`) | `paper/credit_based_flow_control_verification/evidence/generated/reference_model_trace.csv`; asset `img/figures/reference_model_traces.pdf` within the manuscript directory |
| Fig. 5: analytical control-traffic fraction (`fig:control_fraction`) | `paper/credit_based_flow_control_verification/evidence/generated/analytical_control_fraction.csv`; asset `img/figures/analytical_control_fraction.pdf` within the manuscript directory |
| Tables: receiver-capacity risks, acronyms, state variables, and atomic events | Definitions and contract in manuscript Sections I-II; event guards in `paper/credit_based_flow_control_verification/evidence/credit_safety_model.py` |
| Table: UVM source mapping | Source files identified for Fig. 1 and `src/common/i2c_credit_types.sv` |
| Tables: reachable-state counts and matched eight-entry scenarios | `paper/credit_based_flow_control_verification/evidence/generated/reference_model_summary.json` and `reference_model_trace.csv` in the same directory |
| Table: prior-work comparison | Cited works identified in manuscript Section V |
| Algorithm 1: dispatch and return-assisted retry | Contract pseudocode in manuscript Section III; executable accounting in `paper/credit_based_flow_control_verification/evidence/credit_safety_model.py` |
| Listing 1: acceptance-boundary SVA companion check (`lst:sva_tbi1`) | `paper/credit_based_flow_control_verification/evidence/sva/tbi1_compile.sv` and `sva/check_with_pyslang.py` in the same evidence directory; syntax and elaboration only |
| Eleven unit tests, including three selected invalid controls | `paper/credit_based_flow_control_verification/evidence/test_credit_safety_model.py` |
| Syntax-only SystemVerilog audit | `paper/credit_based_flow_control_verification/evidence/static/check_changed_sv_syntax.py` |
| Isolated implementation tests | `tests/credit_contract/run_all.py`; complete RTL modules with Icarus/Verilator, extracted-method tests, and fake-process runner tests; optional real-UVM semantic checks under `semantic/` |
| Revision-specific reproduction archive | `paper/credit_based_flow_control_verification/output/credit_contract_reproduction.zip` |

## Reproducing the Dual-Role Paper

```bash
cd sim
make regr_paper           # 11 scenarios x 15 seeds, recorded in regression_raw.csv
make cov_rpt              # URG coverage report under cov_report/
```

The bus-ownership invariants and mode-flip scoreboard are exercised by `i2c_slave_test`, `i2c_master_fsm_test`, and `i2c_random_test`; the dual-role paper's Table~I aggregates the per-test pass counts and CPU times from `regression_raw.csv`.

## Implemented Features

### Dual-Role VIP

* Master mode: Start/Stop generation, address and data drive, ACK/NACK handling, repeated start, 7-bit and 10-bit addressing, general call.
* Slave mode: Start detection, reactive byte response, configurable ACK/NACK injection.
* Bus ownership invariants and mode-flip coverage in `src/env/`.
* Behavioral RTL master and slave under `rtl/` for closed-loop simulation.

### Credit-Based Flow Control Extension

* The wire scaffold reserves bits [7:6] of each byte for its type. DATA therefore carries six payload bits per byte (0--63); control counts fit 1--63. Event-channel counts have a separately checked 1--256 range. These ranges are not interchangeable, and integrated INIT/RETURN wire transport has not been evaluated.
* CBT source structures reserve the required transaction budget before START, commit ACK-qualified bytes, restore unaccepted reservations on NACK, and abort blocked dispatch at its watchdog deadline. The reference model specializes this to one unresolved byte.
* CBR initialization and return counts use named testbench events. The RTL FIFO-release observation is not connected to that return path.
* The credit monitor uses completion notifications and retained event payloads. Its TBI-1 diagnostic is not a pre-launch observation: a return during a transfer can mask launch-time underflow. TBI-5 belongs to the driver watchdog; there is no independent per-credit latency timer.
* Aggregate return validation is bounded by observed accepted bytes, not physical FIFO releases or return-message identity. The implementation does not independently establish all six reference-model TBIs.
* The executable reference model checks positive-budget dispatch, matched and bounded capacity, initialization ordering, conservation, zero-credit abort eligibility, and release-causal returns.
* The finite model is untimed. It does not establish deadline expiry, a full UVM execution, RTL formal proof, or passive wire-level credit decoding.

The historical `img/seaborn/generate_credit_plots.py` uses synthetic distributions and hardcoded example metrics, not simulator logs. It is not a current manuscript figure generator. Explicit opt-in generation writes labeled illustrations under `img/seaborn/legacy_synthetic/`; historical assets are preserved and must not be presented as measured regression or latency evidence.

## Future Work

* Per-endpoint credit pools for multi-receiver topologies.
* I3C extension with in-band interrupt and dynamic address assignment.
* Formal verification of TBI properties via SystemVerilog Assertions.
* LLM-assisted assertion synthesis from natural-language credit specifications.

## Citation

```bibtex
@article{i2c_dual_role_2026,
  author  = {Liao, Tob and others},
  title   = {Deterministic Dual-Role {I}\textsuperscript{2}{C} Verification with Bus Ownership Invariants},
  journal = {IEEE Access},
  year    = {2026},
  note    = {to appear}
}

@article{i2c_credit_2026,
  author  = {Liao, Yu-Cheng and Huang, Wei-Tzer and Lin, Wei-Chen},
  title   = {Receiver-Capacity Verification for {I}\textsuperscript{2}{C} Endpoints: Transmit-Budget Invariants and Explicit-State Evaluation},
  journal = {IEEE Access},
  year    = {2026},
  note    = {submitted}
}
```

## License

Released for academic reproduction. Please cite the manuscripts above when reusing the verification IP, the RTL models, or the figure-generation scripts in derivative work.
