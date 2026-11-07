`ifndef I2C_CREDIT_RANDOM_TEST_SV
`define I2C_CREDIT_RANDOM_TEST_SV

class i2c_credit_random_test extends i2c_credit_test_base;
  `uvm_component_utils(i2c_credit_random_test)

  function new(string name = "i2c_credit_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void configure_credit_params();
    super.configure_credit_params();
    // Disable soft defaults so the explicitly bounded configuration can vary.
    cfg.c_default_depth.constraint_mode(0);
    if (!cfg.randomize() with {
      // Match the fixed physical RTL FIFO: D=P=8.  Only latency and burst
      // scheduling are randomized in this test.
      cbr_depth == I2C_CREDIT_DEFAULT_DEPTH;
      cbr_pipe_delay inside {[1:4]};
      cbr_return_burst inside {[1:4]};
      cbt_pipe_delay inside {[0:2]};
    }) begin
      `uvm_fatal("TEST", "Bounded credit config randomization failed")
    end
    cfg.c_default_depth.constraint_mode(1);
    `uvm_info("TEST", $sformatf(
      "Randomized credit config: depth=%0d pipe_dly=%0d return_burst=%0d",
      cfg.cbr_depth, cfg.cbr_pipe_delay, cfg.cbr_return_burst), UVM_LOW)
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned remaining_budget;
    int unsigned group_count;
    bit completed;

    phase.raise_objection(this);

    `uvm_info("TEST", ">>> Credit Random Test: randomized write grouping within one matched budget; no RETURN path assumed", UVM_LOW)

    #50us;

    expected_accepted_bytes = $urandom_range(3, cfg.cbr_depth);
    expected_bus_transactions = expected_accepted_bytes;
    remaining_budget = expected_accepted_bytes;
    group_count = 0;
    while (remaining_budget > 0) begin
      int unsigned group_bytes;
      if (remaining_budget >= 2 && $urandom_range(0, 1)) begin
        i2c_credit_burst_sequence seq;
        seq = i2c_credit_burst_sequence::type_id::create("rand_burst_seq");
        seq.cfg = cfg;
        seq.target_addr = cfg.slave_addr;
        seq.burst_count = 2;
        seq.burst_size = $urandom_range(1, remaining_budget / 2);
        group_bytes = seq.burst_count * seq.burst_size;
        start_credit_sequence_bounded(seq, completed);
      end else begin
        group_bytes = $urandom_range(1, remaining_budget);
        run_credit_data_count(group_bytes, "rand_data_seq", completed);
      end
      if (!completed) begin
        phase.drop_objection(this);
        return;
      end
      remaining_budget -= group_bytes;
      group_count++;
      #50us;
    end

    scenario_completed = 1;
    `uvm_info("TEST", $sformatf("Random schedule: groups=%0d total_bytes=%0d remaining_credit=%0d",
      group_count, expected_accepted_bytes, cfg.cbr_depth - expected_accepted_bytes), UVM_LOW)

    `uvm_info("TEST", ">>> Credit Random Test Complete", UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass

`endif // I2C_CREDIT_RANDOM_TEST_SV
