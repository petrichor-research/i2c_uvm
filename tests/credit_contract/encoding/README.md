# Source-derived six-bit credit encoding checks

Run from the repository root:

```sh
python3 tests/credit_contract/encoding/run_directed.py
```

The first Icarus harness extracts the actual encoder, complete-wire-image
validator, and decoder from `src/agent/i2c_transaction.sv`. It checks every
DATA byte in `0..63` for exact preservation, every byte in `64..255` for
rejection without payload mutation, multibyte DATA tags, empty DATA, all
control type/count combinations in `1..63`, and invalid/oversized controls.
Control requests are one byte; event-channel counts up to 256 are a distinct
representation and are not silently truncated into the six-bit wire field.

The second harness extracts the actual sequence task bodies. Procedural
`start_item`/`finish_item` stubs check balanced grants and validate the complete
wire image at both boundaries. Invalid payloads and an unencodable wire INIT
must fail before any grant is requested. Data, burst, exhaustion, and fault
scenario bodies are exercised with the retained six-bit payload convention.

Mechanical lowering removes UVM reports, replaces transaction-object storage
with module fields, removes the enum cast needed only by the class type,
and substitutes grant counters for sequencer methods. Icarus cannot elaborate
packed part-selects directly on dynamic-array elements, so those read-only
slices become equivalent unsigned shift/mask expressions. Actual dynamic arrays,
encoder branches, DATA loops, random payload ranges, and grant ordering remain
the source implementation. Source hashes are printed; `--build-dir` retains
generated harnesses and executables for inspection.

These are source-derived procedural checks, not full UVM execution, RTL
integration, a new byte-header transport, or hardware measurements.
