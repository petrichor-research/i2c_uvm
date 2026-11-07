`ifndef I2C_CREDIT_MONITOR_SV
`define I2C_CREDIT_MONITOR_SV

class i2c_credit_monitor extends uvm_monitor;
  `uvm_component_utils(i2c_credit_monitor)

  virtual i2c_if vif;
  i2c_config cfg;

  int shadow_credit_counter;
  i2c_credit_state_e shadow_state;

  uvm_analysis_port #(i2c_transaction) credit_ap;

  int unsigned tbi1_violations;
  int unsigned tbi2_violations;
  int unsigned tbi3_violations;
  longint signed tbi4_balance_delta;
  // Compatibility field only: TBI-5 is the driver's watchdog diagnostic.
  // This monitor has no blocked-request/deadline observation and never scores it.
  int unsigned tbi5_violations;
  int unsigned tbi6_violations;

  longint unsigned total_credits_init;
  longint unsigned total_credits_consumed;
  longint unsigned total_credits_returned;
  bit init_complete;
  bit physical_release_limitation_reported;

  int credit_history[$];
  time credit_history_time[$];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    credit_ap = new("credit_ap", this);
    shadow_credit_counter = 0;
    shadow_state = CREDIT_STATE_RESET;
    init_complete = 0;
    physical_release_limitation_reported = 0;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(i2c_config)::get(this, "", "cfg", cfg)) begin
      `uvm_fatal("CREDIT_MON",
        "Credit monitor requires the test's explicitly configured i2c_config")
    end
    if (!uvm_config_db#(virtual i2c_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("CREDIT_MON", "Virtual interface 'vif' not found")
    end
  endfunction

  task run_phase(uvm_phase phase);
    if (!cfg.credit_mode_enable) return;

    `uvm_warning("CREDIT_MON",
      "TBI-1 is checked at TRANS_COMPLETE, not launch: a RETURN received during the transfer can mask an uncredited launch; TBI-5 is a driver watchdog diagnostic, not a monitor latency bound")
    physical_release_limitation_reported = 1;
    `uvm_warning("CREDIT_MON",
      "No endpoint-local physical FIFO-free observation is connected; TBI-6 is limited to return-versus-accepted-byte ordering")

    fork
      monitor_credit_init();
      monitor_accepted_write_bytes();
      monitor_credit_returns();
      record_credit_history();
    join
  endtask

  task monitor_credit_init();
    bit timed_out;
    i2c_credit_event_payload init_event;
    i2c_event_pool::wait_for_credit_init_timeout(
      I2C_CREDIT_CONSUMER_MONITOR,
      cfg.credit_init_timeout_ns * 1ns,
      timed_out, init_event);

    if (timed_out) begin
      `uvm_error("CREDIT_MON", "Credit init not observed within timeout")
      tbi3_violations++;
    end else begin
      void'(apply_credit_init(init_event));
    end
  endtask

  function bit apply_credit_init(i2c_credit_event_payload init_event);
    if (init_event == null) begin
      tbi3_violations++;
      `uvm_error("CREDIT_MON", "TBI-3: null INIT payload")
      return 0;
    end else if (init_complete) begin
      tbi3_violations++;
      `uvm_error("CREDIT_MON", "TBI-3: duplicate INIT grant")
      return 0;
    end else if (init_event.frame_type != I2C_CREDIT_FRAME_INIT ||
                 init_event.credit_count == 0 ||
                 init_event.credit_count > I2C_CREDIT_MAX_DEPTH ||
                 init_event.credit_count != cfg.cbr_depth) begin
      tbi3_violations++;
      `uvm_error("CREDIT_MON", $sformatf(
        "TBI-3: invalid INIT payload advertised=%0d configured=%0d",
        init_event.credit_count, cfg.cbr_depth))
      return 0;
    end else if (shadow_credit_counter != 0 || total_credits_consumed != 0 ||
                 total_credits_returned != 0) begin
      tbi3_violations++;
      `uvm_error("CREDIT_MON", "TBI-3: INIT cannot erase accounting from DATA observed before initialization")
      return 0;
    end else begin
      shadow_credit_counter = int'(init_event.credit_count);
      total_credits_init = init_event.credit_count;
      init_complete = 1;
      shadow_state = CREDIT_STATE_READY;
      `uvm_info("CREDIT_MON", $sformatf("Init observed: shadow_counter=%0d", shadow_credit_counter), UVM_MEDIUM)
      return 1;
    end
  endfunction

  task monitor_accepted_write_bytes();
    forever begin
      uvm_object event_data;
      i2c_transaction tr;
      i2c_event_pool::wait_for_event(i2c_event_pool::TRANS_COMPLETE, event_data);
      if (!$cast(tr, event_data)) begin
        `uvm_error("CREDIT_MON", "TRANS_COMPLETE did not carry an i2c_transaction")
        continue;
      end

      observe_completed_write(tr);
    end
  endtask

  function void observe_completed_write(i2c_transaction tr);
    int unsigned attempted_count;
    int unsigned accepted_count;
    if (tr == null) begin
      `uvm_error("CREDIT_MON", "Null completed transaction")
      return;
    end
    // Completion-time accounting only.  There is no retained, transaction-
    // matched pre-START budget observation in the current source topology.
    // Reads and control frames do not consume this write-byte budget.
    if (tr.direction != I2C_WRITE || tr.status == I2C_STATUS_ADDR_NACK)
      return;
    // Do not infer all-byte DATA qualification from only the first tag.
    // A malformed mixed DATA/control image must not become accepted capacity.
    if (!tr.valid_credit_encoding()) begin
      `uvm_error("CREDIT_MON", "Rejected malformed complete credit wire image without changing credit accounting")
      return;
    end
    if (tr.frame_type != I2C_CREDIT_FRAME_DATA) return;

    attempted_count = tr.data.size();
    check_tbi1(attempted_count);

    if (!init_complete) begin
      tbi3_violations++;
      `uvm_error("CREDIT_MON", "TBI-3: DATA bytes observed before valid credit INIT")
    end

    // Only ACK-qualified write bytes change the accounting balance.  A
    // NACKed byte can establish a completion-time budget deficit through
    // check_tbi1(), but it does not consume receiver capacity.
    accepted_count = tr.accepted_data_bytes;
    if (accepted_count > attempted_count) begin
      `uvm_error("CREDIT_MON", "Completed transaction has more accepted than attempted bytes")
      return;
    end
    if (accepted_count == 0)
      return;

    shadow_credit_counter -= int'(accepted_count);
    total_credits_consumed += accepted_count;
    check_tbi2();
  endfunction

  task monitor_credit_returns();
    forever begin
      i2c_credit_event_payload return_event;
      i2c_event_pool::wait_for_credit_return(
        I2C_CREDIT_CONSUMER_MONITOR, return_event);

      void'(apply_credit_return(return_event));
    end
  endtask

  // Validate the complete proposed update before touching accounting state.
  // R <= accepted bytes is only an event-ordering check, not evidence of F.
  function bit apply_credit_return(i2c_credit_event_payload return_event);
    string reason = "";
    bit would_overflow = 0;
    if (return_event == null)
      reason = "null payload";
    else if (!init_complete)
      reason = "RETURN before valid INIT";
    else if (return_event.frame_type != I2C_CREDIT_FRAME_RETURN ||
             return_event.credit_count == 0 ||
             return_event.credit_count > I2C_CREDIT_MAX_DEPTH)
      reason = "malformed type/count";
    else if (shadow_credit_counter < 0 ||
             shadow_credit_counter > int'(cfg.cbr_depth))
      reason = "existing shadow counter is outside its configured bounds";
    else if (return_event.credit_count > cfg.cbr_depth ||
             int'(return_event.credit_count) > int'(cfg.cbr_depth) - shadow_credit_counter) begin
      reason = "RETURN would exceed configured depth";
      would_overflow = 1;
    end else if (total_credits_returned > total_credits_consumed ||
                 return_event.credit_count > total_credits_consumed - total_credits_returned)
      reason = "RETURN exceeds observed accepted-byte balance";

    if (reason != "") begin
      tbi6_violations++;
      if (would_overflow) tbi2_violations++;
      `uvm_error("CREDIT_MON", $sformatf("Rejected credit RETURN: %s", reason))
      return 0;
    end

    shadow_credit_counter += int'(return_event.credit_count);
    total_credits_returned += return_event.credit_count;
    return 1;
  endfunction

  task record_credit_history();
    forever begin
      credit_history.push_back(shadow_credit_counter);
      credit_history_time.push_back($time);
      #(cfg.t_low_ns * 1ns);
    end
  endtask

  function void check_tbi1(int unsigned attempted_count);
    if (attempted_count > 0 &&
        longint'(shadow_credit_counter) < longint'(attempted_count)) begin
      tbi1_violations++;
      `uvm_error("CREDIT_MON", $sformatf(
        "TBI-1 VIOLATION (completion-time diagnostic): attempted=%0d current_available=%0d (launch budget not observed)",
        attempted_count, shadow_credit_counter))
    end
  endfunction

  function void check_tbi2();
    if (shadow_credit_counter > int'(cfg.cbr_depth)) begin
      tbi2_violations++;
      `uvm_error("CREDIT_MON", $sformatf(
        "TBI-2 VIOLATION: shadow_credit_counter=%0d > cbr_depth=%0d",
        shadow_credit_counter, cfg.cbr_depth))
    end
  endfunction

  // This is the event-ordering subcheck only (R <= accepted DATA bytes).  A
  // proof that every RETURN follows a physical FIFO release requires a FIFO-pop
  // observation, which is not connected in the current event-mode integration.
  function void check_tbi6();
    if (total_credits_returned > total_credits_consumed) begin
      tbi6_violations++;
      `uvm_error("CREDIT_MON", $sformatf(
        "TBI-6 VIOLATION: credits_returned=%0d > credits_consumed=%0d",
        total_credits_returned, total_credits_consumed))
    end
  endfunction

  function void check_phase(uvm_phase phase);
    longint signed expected_balance;
    super.check_phase(phase);
    if (!cfg.credit_mode_enable) return;

    // Completion-time conservation only. Outstanding accepted bytes need not
    // have returned credits at test end; no physical drain/closure is observed.
    expected_balance = longint'(total_credits_init) -
                       longint'(total_credits_consumed) +
                       longint'(total_credits_returned);
    tbi4_balance_delta = longint'(shadow_credit_counter) - expected_balance;

    if (tbi4_balance_delta != 0) begin
      `uvm_error("CREDIT_MON", $sformatf(
        "TBI-4: Accounting conservation mismatch: counter=%0d expected=%0d delta=%0d (init=%0d consumed=%0d returned=%0d)",
        shadow_credit_counter, expected_balance, tbi4_balance_delta,
        total_credits_init, total_credits_consumed, total_credits_returned))
    end
  endfunction

  function void report_phase(uvm_phase phase);
    if (!cfg.credit_mode_enable) return;

    `uvm_info("CREDIT_MON", "╔════════════════════════════════════════╗", UVM_NONE)
    `uvm_info("CREDIT_MON", "║     CREDIT MONITOR REPORT              ║", UVM_NONE)
    `uvm_info("CREDIT_MON", "╠════════════════════════════════════════╣", UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ Credits Initialized : %8d         ║", total_credits_init), UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ Credits Consumed    : %8d         ║", total_credits_consumed), UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ Credits Returned    : %8d         ║", total_credits_returned), UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ Final Counter       : %8d         ║", shadow_credit_counter), UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ TBI-1 Violations    : %8d         ║", tbi1_violations), UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ TBI-2 Violations    : %8d         ║", tbi2_violations), UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ TBI-3 Violations    : %8d         ║", tbi3_violations), UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ TBI-4 Residual      : %8d         ║", tbi4_balance_delta), UVM_NONE)
    `uvm_info("CREDIT_MON", "║ TBI-5: driver watchdog only             ║", UVM_NONE)
    `uvm_info("CREDIT_MON", $sformatf("║ TBI-6 Violations    : %8d         ║", tbi6_violations), UVM_NONE)
    `uvm_info("CREDIT_MON", "╚════════════════════════════════════════╝", UVM_NONE)
    `uvm_info("CREDIT_MON",
      "TBI-1 scope: completion-time budget diagnostic only; returns during a transfer can mask launch-time underflow. TBI-5 is not checked by this monitor.",
      UVM_NONE)
    if (physical_release_limitation_reported)
      `uvm_info("CREDIT_MON",
        "TBI-6 scope: return ordering checked; physical FIFO-release causality not observed",
        UVM_NONE)
  endfunction

endclass

`endif // I2C_CREDIT_MONITOR_SV
