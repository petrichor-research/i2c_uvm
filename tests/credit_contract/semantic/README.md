# Real-UVM source type/elaboration check

This check uses the actual Accellera UVM 1.2 library and macros, not inert
macro stubs or procedural substitutes. Obtain the official archive from:

<https://www.accellera.org/images/downloads/standards/uvm/uvm-1.2.tar.gz>

The archive inspected on 7 November 2026 has SHA-256:

```text
502a2e605ce552bfd9767803c7e99a053715b00f7a9c4c511c3fbfddfb30157c
```

Extract it outside the repository; this directory does not vendor UVM.
Install `pyslang==11.0.0` using Python 3.12 and run from the repository root:

```sh
python3 -m pip install -r tests/credit_contract/semantic/requirements.txt
python3 tests/credit_contract/semantic/check_with_real_uvm.py --uvm-home /absolute/path/uvm-1.2
python3 tests/credit_contract/semantic/check_with_real_uvm.py --uvm-home /absolute/path/uvm-1.2 --positive-control
```

The positive control inserts a nonexistent config member into a compiler-input
buffer. It succeeds only if semantic checking detects that missing member;
it does not change a repository file. The ordinary check parses and obtains
all semantic diagnostics for the interface, real UVM package, project packages
and their includes, three RTL modules, and `tb_top`. Input paths, command
options, and top-level source hashes are printed.

The checked configuration defines the official `UVM_NO_DPI` option and uses
the build's `1ns/1ps` time scale. Optional FSDB calls are excluded by default;
enable `+define+I2C_ENABLE_FSDB` and link the vendor dumper when using a
simulator that supplies those tasks. The semantic checker suppresses no
unknown-system-name diagnostics and does not normalize repository source.

Observed on 7 November 2026 with the archive checksum above: the ordinary
check completed with zero errors and two empty-loop-body warnings inside
unmodified UVM library files (`uvm_resource.svh` and `uvm_sequencer.svh`).
The positive control produced the intended `UnknownMember` error for the
in-memory config-member probe. The project packages' callback and virtual-
sequencer declarations resolved in their current include order; no additional
missing member, type, or UVM API error was reported in this configuration.

This is a source type/elaboration check with PySlang, not a VCS compilation,
linked DPI/FSDB build, UVM test execution, measured coverage, or proof of
runtime protocol behavior. A successful result does not close those gates.
