`ifndef I2C_CREDIT_EXHAUSTION_TEST_SV
`define I2C_CREDIT_EXHAUSTION_TEST_SV

// Count one exact expected error without suppressing or demoting its report.
class i2c_credit_watchdog_catcher extends uvm_report_catcher;
  int unsigned expected_count;
  int unsigned unexpected_count;

  function new(string name = "i2c_credit_watchdog_catcher");
    super.new(name);
    expected_count = 0;
    unexpected_count = 0;
  endfunction

  virtual function action_e catch();
    if (get_severity() == UVM_ERROR) begin
      if (get_id() == "CBT_DRV" &&
          get_message() == "TBI-5 diagnostic timeout: pending DATA aborted without transmission")
        expected_count++;
      else
        unexpected_count++;
    end
    return THROW;
  endfunction
endclass

class i2c_credit_exhaustion_test extends i2c_credit_test_base;
  `uvm_component_utils(i2c_credit_exhaustion_test)

  i2c_credit_watchdog_catcher watchdog_catcher;
  bit watchdog_response_ok;
  int unsigned blocked_bus_transitions;

  function new(string name = "i2c_credit_exhaustion_test", uvm_component parent = null);
    super.new(name, parent);
    watchdog_response_ok = 0;
    blocked_bus_transitions = 0;
  endfunction

  virtual function void configure_credit_params();
    super.configure_credit_params();
    // The instantiated RTL FIFO has P=8 entries; physical evidence therefore
    // uses the matched advertised depth D=P=8.
    cfg.cbr_depth = I2C_CREDIT_DEFAULT_DEPTH;
    cfg.cbr_pipe_delay = 3;
  endfunction

  task run_phase(uvm_phase phase);
    i2c_credit_probe_sequence probe;
    bit completed;
    virtual i2c_if bus_vif;

    phase.raise_objection(this);
    expected_accepted_bytes = cfg.cbr_depth;
    expected_bus_transactions = cfg.cbr_depth;
    expected_stall_episodes = 1;
    bus_vif = env.agent.cbt_driver.vif;
    watchdog_catcher = new();
    uvm_report_cb::add(env.agent.cbt_driver, watchdog_catcher);

    `uvm_info("TEST", ">>> Credit Exhaustion Test: D accepted writes, then one expected watchdog abort without bus launch; no recovery claimed", UVM_LOW)

    #50us;
    run_credit_data_count(cfg.cbr_depth, "fill_initial_budget", completed);
    if (!completed) begin
      uvm_report_cb::delete(env.agent.cbt_driver, watchdog_catcher);
      phase.drop_objection(this);
      return;
    end

    probe = i2c_credit_probe_sequence::type_id::create("blocked_ninth_request");
    probe.cfg = cfg;
    probe.target_addr = cfg.slave_addr;
    fork : blocked_request_guard
      begin
        start_credit_sequence_bounded(probe, completed);
      end
      begin
        forever begin
          @(bus_vif.scl or bus_vif.sda);
          blocked_bus_transitions++;
        end
      end
    join_any
    disable blocked_request_guard;
    #1ns;
    uvm_report_cb::delete(env.agent.cbt_driver, watchdog_catcher);

    if (probe.result != null) begin
      watchdog_response_ok = completed &&
        probe.result.status == I2C_STATUS_TIMEOUT &&
        probe.result.accepted_data_bytes == 0 && !probe.result.nack_received;
    end
    scenario_completed = watchdog_response_ok && blocked_bus_transitions == 0;
    if (!scenario_completed)
      `uvm_error("TEST", $sformatf(
        "Exhaustion oracle failed: completed=%0b TIMEOUT/zero-accept response=%0b bus_transitions=%0d",
        completed, watchdog_response_ok, blocked_bus_transitions))

    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server svr;
    bit oracle_ok;
    svr = uvm_report_server::get_server();
    oracle_ok = 0;
    if (watchdog_catcher != null) begin
      oracle_ok = scenario_completed && watchdog_response_ok &&
        blocked_bus_transitions == 0 && watchdog_catcher.expected_count == 1 &&
        watchdog_catcher.unexpected_count == 0 &&
        svr.get_severity_count(UVM_ERROR) == 1 &&
        svr.get_severity_count(UVM_FATAL) == 0;
    end
    if (oracle_ok) begin
      $display("TEST STATUS: PASSED (observed exactly 1 expected TBI-5 timeout; no DATA launch)");
    end else begin
      `uvm_error("TEST", "Expected watchdog oracle failed: require exactly one CBT watchdog error, TIMEOUT response, no bus launch, and intact accounting")
      $display("TEST STATUS: FAILED (expected watchdog oracle mismatch)");
    end
  endfunction

endclass

`endif // I2C_CREDIT_EXHAUSTION_TEST_SV
