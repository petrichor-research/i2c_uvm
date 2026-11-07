`ifndef I2C_CREDIT_DUAL_ROLE_TEST_SV
`define I2C_CREDIT_DUAL_ROLE_TEST_SV

class i2c_credit_dual_role_test extends i2c_credit_test_base;
  `uvm_component_utils(i2c_credit_dual_role_test)

  int unsigned logical_role_commits;
  bit resumed_after_role_switch;

  function new(string name = "i2c_credit_dual_role_test", uvm_component parent = null);
    super.new(name, parent);
    logical_role_commits = 0;
    resumed_after_role_switch = 0;
  endfunction

  virtual function void configure_credit_params();
    super.configure_credit_params();
    cfg.cbr_depth = 8;
    cfg.cbr_pipe_delay = 2;
  endfunction

  // Check the present bus level for a full tBUF, not an already-consumed pulse.
  task wait_for_stable_idle(time timeout, output bit idle_ok);
    virtual i2c_if bus_vif;
    bus_vif = env.agent.cbt_driver.vif;
    idle_ok = 0;
    fork : idle_deadline
      begin
        forever begin
          wait(bus_vif.scl === 1'b1 && bus_vif.sda === 1'b1);
          fork : idle_sample
            begin
              #(cfg.t_buf_ns * 1ns);
              idle_ok = (bus_vif.scl === 1'b1 && bus_vif.sda === 1'b1);
            end
            begin
              wait(bus_vif.scl !== 1'b1 || bus_vif.sda !== 1'b1);
            end
          join_any
          disable idle_sample;
          if (idle_ok) break;
        end
      end
      begin #(timeout); end
    join_any
    disable idle_deadline;
  endtask

  task run_phase(uvm_phase phase);
    bit completed;
    bit idle_ok;
    int credits_before;
    int shadow_before;
    int unsigned cbr_received_before;
    int unsigned cbr_returned_before;

    phase.raise_objection(this);
    expected_accepted_bytes = 7;
    expected_bus_transactions = expected_accepted_bytes;

    if (env.agent.cbt_driver == null || env.agent.cbr_driver == null ||
        env.agent.credit_monitor == null)
      `uvm_fatal("TEST", "Logical role-switch test requires the active credit components")
    `uvm_info("TEST",
      ">>> Credit logical role-switch test: no peer controller or slave-role traffic is enabled", UVM_LOW)
    #50us;
    run_credit_data_count(4, "before_role_switch", completed);
    if (!completed) begin
      phase.drop_objection(this);
      return;
    end

    wait_for_stable_idle(200us, idle_ok);
    if (!idle_ok) begin
      `uvm_error("TEST", "Unexpected bus-idle timeout before logical role commit")
      phase.drop_objection(this);
      return;
    end
    credits_before = env.agent.cbt_driver.credit_counter;
    shadow_before = env.agent.credit_monitor.shadow_credit_counter;
    cbr_received_before = env.agent.cbr_driver.total_data_received;
    cbr_returned_before = env.agent.cbr_driver.total_credits_returned;

    // This is a harness configuration commit, not a driver acknowledgment.
    // ROLE_COMMITTED has no production publisher, so do not fake that event.
    cfg.is_master = 0;
    logical_role_commits++;
    i2c_event_pool::trigger_event(i2c_event_pool::ROLE_UPDATE);
    `uvm_info("TEST", "Logical role committed: slave listen only; no slave transfer claimed", UVM_LOW)
    #100us;

    // The CBR's listen is cancelled by cfg.is_master becoming true.  It must
    // not account a phantom receive or enqueue a return when no byte arrived.
    cfg.is_master = 1;
    logical_role_commits++;
    i2c_event_pool::trigger_event(i2c_event_pool::ROLE_UPDATE);
    #(2 * env.agent.cbr_driver.idle_poll_time + 1ns);
    `uvm_info("TEST", "Logical role committed: master; checking quiet-listen cancellation and resume", UVM_LOW)
    if (env.agent.cbr_driver.total_data_received != cbr_received_before ||
        env.agent.cbr_driver.total_credits_returned != cbr_returned_before ||
        env.agent.cbr_driver.cr_return_pipe.size() != 0 ||
        env.agent.cbt_driver.credit_counter != credits_before ||
        env.agent.credit_monitor.shadow_credit_counter != shadow_before) begin
      `uvm_error("TEST", "Quiet role interval changed credit or receiver accounting")
    end

    wait_for_stable_idle(200us, idle_ok);
    if (!idle_ok) begin
      `uvm_error("TEST", "Unexpected bus-idle timeout after cancelling slave listen")
      phase.drop_objection(this);
      return;
    end
    run_credit_data_count(3, "after_role_switch", completed);
    resumed_after_role_switch = completed;
    scenario_completed = completed;
    `uvm_info("TEST", $sformatf(
      "Logical role-switch result: commits=%0d resumed=%0b slave_receive_delta=%0d (no slave traffic generated)",
      logical_role_commits, resumed_after_role_switch,
      env.agent.cbr_driver.total_data_received - cbr_received_before), UVM_LOW)

    phase.drop_objection(this);
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (logical_role_commits != 2 || !resumed_after_role_switch)
      `uvm_error("TEST", "Logical role-switch test did not complete both commits and ACK-qualified resume")
  endfunction

endclass

`endif // I2C_CREDIT_DUAL_ROLE_TEST_SV
