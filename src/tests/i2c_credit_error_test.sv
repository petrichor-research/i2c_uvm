`ifndef I2C_CREDIT_ERROR_TEST_SV
`define I2C_CREDIT_ERROR_TEST_SV

class i2c_credit_error_test extends i2c_credit_test_base;
  `uvm_component_utils(i2c_credit_error_test)

  localparam int unsigned EXPECTED_TBI1_VIOLATIONS = 3;

  function new(string name = "i2c_credit_error_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void configure_credit_params();
    super.configure_credit_params();
    cfg.cbr_depth = I2C_CREDIT_DEFAULT_DEPTH;
    cfg.inject_send_without_credit = 1;
  endfunction

  task run_phase(uvm_phase phase);
    i2c_credit_error_sequence err_seq;
    bit completed;

    phase.raise_objection(this);
    expected_accepted_bytes = cfg.cbr_depth;
    expected_bus_transactions = cfg.cbr_depth + EXPECTED_TBI1_VIOLATIONS;
    expected_tbi1_diagnostics = EXPECTED_TBI1_VIOLATIONS;

    `uvm_info("TEST", ">>> Credit Error Test: inject protocol violations, verify monitor catches them", UVM_LOW)

    #50us;

    err_seq = i2c_credit_error_sequence::type_id::create("err_seq");
    err_seq.cfg = cfg;
    err_seq.target_addr = cfg.slave_addr;
    err_seq.scenario = i2c_credit_error_sequence::ERR_SEND_WITHOUT_CREDIT;
    start_credit_sequence_bounded(err_seq, completed);
    scenario_completed = completed;

    `uvm_info("TEST", ">>> Credit Error Test Complete", UVM_LOW)
    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server svr;
    int unsigned observed_tbi1;
    bit oracle_ok;
    svr = uvm_report_server::get_server();
    observed_tbi1 = (env.agent.credit_monitor == null) ? 0 :
                    env.agent.credit_monitor.tbi1_violations;
    oracle_ok = 0;
    if (env.agent.credit_monitor != null) begin
      oracle_ok = scenario_completed &&
                  (observed_tbi1 == EXPECTED_TBI1_VIOLATIONS) &&
                  (env.agent.credit_monitor.tbi2_violations == 0) &&
                  (env.agent.credit_monitor.tbi3_violations == 0) &&
                  (env.agent.credit_monitor.tbi5_violations == 0) &&
                  (env.agent.credit_monitor.tbi6_violations == 0) &&
                  (env.agent.credit_monitor.total_credits_consumed ==
                    cfg.cbr_depth) &&
                  (env.agent.credit_monitor.shadow_credit_counter == 0) &&
                  (svr.get_severity_count(UVM_ERROR) == EXPECTED_TBI1_VIOLATIONS) &&
                  (svr.get_severity_count(UVM_FATAL) == 0);
    end
    `uvm_info("TEST", $sformatf("Observed UVM errors before oracle check: %0d",
      svr.get_severity_count(UVM_ERROR)), UVM_LOW)
    if (oracle_ok) begin
      $display("\n========================================================");
      $display("    TEST STATUS: PASSED (observed exactly %0d TBI-1 violations)",
        observed_tbi1);
      $display("========================================================\n");
    end else begin
      `uvm_error("TEST", $sformatf(
        "Error-injection oracle failed: expected TBI1=%0d, other TBI violations=0, accepted=%0d, shadow=%0d, UVM_ERROR=%0d; observed TBI1=%0d, UVM_ERROR=%0d",
        EXPECTED_TBI1_VIOLATIONS,
        cfg.cbr_depth, 0, EXPECTED_TBI1_VIOLATIONS,
        observed_tbi1, svr.get_severity_count(UVM_ERROR)))
      $display("\n========================================================");
      $display("    TEST STATUS: FAILED (error-injection oracle mismatch)");
      $display("========================================================\n");
    end
  endfunction

endclass

`endif // I2C_CREDIT_ERROR_TEST_SV
