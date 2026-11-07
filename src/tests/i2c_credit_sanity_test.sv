`ifndef I2C_CREDIT_SANITY_TEST_SV
`define I2C_CREDIT_SANITY_TEST_SV

class i2c_credit_sanity_test extends i2c_credit_test_base;
  `uvm_component_utils(i2c_credit_sanity_test)

  function new(string name = "i2c_credit_sanity_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    bit completed;

    phase.raise_objection(this);

    expected_accepted_bytes = cfg.cbr_depth / 2;
    expected_bus_transactions = expected_accepted_bytes;
    `uvm_info("TEST", ">>> Credit Sanity Test: within-budget writes and outstanding-byte conservation; no RETURN assumed", UVM_LOW)

    #50us;

    run_credit_data_count(expected_accepted_bytes, "sanity_data", completed);
    scenario_completed = completed;

    `uvm_info("TEST", ">>> Credit Sanity Test Complete", UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass

`endif // I2C_CREDIT_SANITY_TEST_SV
