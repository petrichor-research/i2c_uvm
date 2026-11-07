`ifndef I2C_CREDIT_BURST_TEST_SV
`define I2C_CREDIT_BURST_TEST_SV

class i2c_credit_burst_test extends i2c_credit_test_base;
  `uvm_component_utils(i2c_credit_burst_test)

  function new(string name = "i2c_credit_burst_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void configure_credit_params();
    super.configure_credit_params();
    cfg.cbr_depth = I2C_CREDIT_DEFAULT_DEPTH;
    cfg.cbr_pipe_delay = 2;
  endfunction

  task run_phase(uvm_phase phase);
    i2c_credit_burst_sequence burst_seq;
    bit completed;

    phase.raise_objection(this);

    `uvm_info("TEST", ">>> Credit Burst Test: multiple groups within one eight-credit budget; no RETURN recovery claimed", UVM_LOW)

    #50us;

    burst_seq = i2c_credit_burst_sequence::type_id::create("burst_seq");
    burst_seq.cfg = cfg;
    burst_seq.target_addr = cfg.slave_addr;
    if (!burst_seq.randomize() with {
      burst_count inside {[2:4]};
      burst_size inside {[1:4]};
      burst_count * burst_size <= cfg.cbr_depth;
    }) `uvm_fatal("TEST", "Randomization failed")

    expected_accepted_bytes = burst_seq.burst_count * burst_seq.burst_size;
    expected_bus_transactions = expected_accepted_bytes;
    start_credit_sequence_bounded(burst_seq, completed);
    scenario_completed = completed;

    `uvm_info("TEST", ">>> Credit Burst Test Complete", UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass

`endif // I2C_CREDIT_BURST_TEST_SV
