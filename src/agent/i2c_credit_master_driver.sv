`ifndef I2C_CREDIT_MASTER_DRIVER_SV
`define I2C_CREDIT_MASTER_DRIVER_SV

class i2c_credit_master_driver extends i2c_driver;
  `uvm_component_utils(i2c_credit_master_driver)

  int credit_counter;
  i2c_credit_state_e credit_state;

  int unsigned total_data_sent;
  int unsigned total_stall_cycles;
  int unsigned total_credits_received;
  bit init_complete;
  int unsigned credit_epoch;
  i2c_status_e wait_failure_status;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    credit_counter = 0;
    credit_state = CREDIT_STATE_RESET;
    total_data_sent = 0;
    total_stall_cycles = 0;
    total_credits_received = 0;
    init_complete = 0;
    credit_epoch = i2c_event_pool::reset_epoch;
    wait_failure_status = I2C_STATUS_ERROR;
  endfunction

  task run_phase(uvm_phase phase);
    bit init_ok;

    vif.scl_drive <= 1'b1;
    vif.sda_drive <= 1'b1;

    if (!cfg.credit_mode_enable) begin
      super.run_phase(phase);
      return;
    end

    wait_for_credit_init(init_ok);
    if (!init_ok) begin
      `uvm_error("CBT_DRV", "Credit dispatch disabled because initialization did not complete")
    end

    forever begin
      bit channels_ok;
      channels_ok = drain_credit_channels();
      if (cfg.is_master) begin
        req = null;
        seq_item_port.try_next_item(req);
        if (req != null) begin
          dispatch_request(req, channels_ok);
          seq_item_port.item_done();
        end else begin
          bit timed_out;
          i2c_event_pool::wait_for_event_timeout(
            i2c_event_pool::ROLE_UPDATE, idle_poll_time, timed_out);
        end
      end else begin
        // The CBR is the sole slave responder.  A second listener here would
        // race it on the shared open-drain contribution and duplicate service.
        bit timed_out;
        i2c_event_pool::wait_for_event_timeout(
          i2c_event_pool::ROLE_UPDATE, idle_poll_time, timed_out);
      end
    end
  endtask

  task dispatch_request(i2c_transaction tr, bit channels_ok);
    bit dispatch_ok;
    int unsigned reservation;
    int unsigned rollback;
    int unsigned request_epoch;
    if (tr == null) return;
    tr.accepted_data_bytes = 0;
    tr.nack_received = 0;
    tr.status = I2C_STATUS_ERROR;
    wait_failure_status = I2C_STATUS_ERROR;
    request_epoch = credit_epoch;
    if (!cfg.is_master || !channels_ok || !init_complete ||
        credit_epoch != i2c_event_pool::reset_epoch) begin
      `uvm_error("CBT_DRV", "Request rejected without bus drive: credit session is not valid")
      return;
    end
    // No credit-read transport is implemented. Validate the complete encoded
    // write image, including every DATA tag, before any reservation or START.
    if (tr.direction != I2C_WRITE || !tr.valid_credit_encoding()) begin
      `uvm_error("CBT_DRV", "Unsupported direction or invalid complete credit wire image; request not driven")
      return;
    end
    if (tr.frame_type != I2C_CREDIT_FRAME_DATA) begin
      drive_transfer(tr);
      return;
    end

    reservation = tr.data.size();
    wait_for_credit(reservation, dispatch_ok);
    if (!dispatch_ok) begin
      tr.status = wait_failure_status;
      return;
    end
    credit_counter -= reservation;
    update_credit_state();
    drive_transfer(tr);

    // Do not evaluate unsigned reservation-accepted arithmetic until the
    // accepted count is known to be within the reservation. An impossible
    // result or intervening reset invalidates the session instead of minting
    // a guessed rollback grant.
    if (tr.accepted_data_bytes > reservation ||
        credit_epoch != request_epoch || i2c_event_pool::reset_epoch != request_epoch) begin
      `uvm_error("CBT_DRV", "Invalid accepted count or reset during DATA drive; credit session disabled")
      credit_counter = 0;
      init_complete = 0;
      credit_state = CREDIT_STATE_ERROR;
      tr.status = I2C_STATUS_ERROR;
      tr.accepted_data_bytes = 0;
      tr.nack_received = 0;
      return;
    end
    rollback = reservation - tr.accepted_data_bytes;
    credit_counter += rollback;
    total_data_sent += tr.accepted_data_bytes;
    update_credit_state();
  endtask

  task wait_for_credit_init(output bit initialized);
    bit timed_out;
    i2c_credit_event_payload init_event;
    initialized = 0;
    init_complete = 0;
    credit_counter = 0;
    credit_epoch = i2c_event_pool::reset_epoch;
    `uvm_info("CBT_DRV", "Waiting for credit initialization...", UVM_LOW)
    credit_state = CREDIT_STATE_INIT;

    fork
      i2c_event_pool::wait_for_credit_init_timeout(
        I2C_CREDIT_CONSUMER_CBT,
        cfg.credit_init_timeout_ns * 1ns,
        timed_out, init_event);
      begin
        wait(i2c_event_pool::reset_epoch != credit_epoch);
        timed_out = 1;
      end
    join_any
    disable fork;

    if (timed_out || credit_epoch != i2c_event_pool::reset_epoch) begin
      `uvm_error("CBT_DRV", "Credit initialization timed out")
      credit_state = CREDIT_STATE_ERROR;
      return;
    end

    if (init_event == null) begin
      `uvm_error("CBT_DRV", "Rejected credit INIT payload: null handle")
      credit_state = CREDIT_STATE_ERROR;
      return;
    end

    if (init_event.frame_type != I2C_CREDIT_FRAME_INIT ||
        init_event.credit_count == 0 ||
        init_event.credit_count > I2C_CREDIT_MAX_DEPTH ||
        init_event.credit_count != cfg.cbr_depth) begin
      `uvm_error("CBT_DRV", $sformatf(
        "Rejected credit INIT payload: advertised=%0d configured=%0d",
        init_event.credit_count, cfg.cbr_depth))
      credit_state = CREDIT_STATE_ERROR;
      return;
    end

    credit_counter = init_event.credit_count;
    total_credits_received = init_event.credit_count;
    credit_state = CREDIT_STATE_READY;
    initialized = 1;
    init_complete = 1;
    `uvm_info("CBT_DRV", $sformatf("Credit init complete: %0d credits available", credit_counter), UVM_LOW)
  endtask

  task wait_for_credit(input int unsigned required, output bit dispatch_ok);
    time deadline;
    time remaining;
    uvm_event return_available;
    dispatch_ok = 0;
    wait_failure_status = I2C_STATUS_ERROR;
    deadline = $time + cfg.credit_stall_timeout_ns * 1ns;
    return_available = i2c_event_pool::get_credit_return_available_event(
      I2C_CREDIT_CONSUMER_CBT);

    if (required == 0 || cfg.cbr_depth == 0 || cfg.cbr_depth > I2C_CREDIT_MAX_DEPTH) begin
      `uvm_error("CBT_DRV", "DATA length or configured credit depth is not credit-accountable")
      return;
    end

    if (required > cfg.cbr_depth) begin
      `uvm_error("CBT_DRV", $sformatf(
        "DATA transaction requires %0d credits but matched depth is %0d",
        required, cfg.cbr_depth))
      return;
    end

    if (!cfg.is_master || !init_complete ||
        credit_epoch != i2c_event_pool::reset_epoch ||
        !drain_credit_channels()) return;

    if (cfg.inject_send_without_credit) begin
      dispatch_ok = 1;
      return;
    end

    if (credit_counter < int'(required)) begin
      credit_state = CREDIT_STATE_EXHAUSTED;
      total_stall_cycles++;
      i2c_event_pool::trigger_event("credit_exhausted");
    end
    while (credit_counter < int'(required)) begin
      if (!cfg.is_master || credit_epoch != i2c_event_pool::reset_epoch)
        return;
      // Recheck retained payloads before deciding the deadline expired.  The
      // single absolute deadline is not extended by partial grants.
      if (!drain_credit_channels()) return;
      if (credit_counter >= int'(required)) break;
      if ($time >= deadline) begin
        `uvm_error("CBT_DRV", "TBI-5 diagnostic timeout: pending DATA aborted without transmission")
        wait_failure_status = I2C_STATUS_TIMEOUT;
        credit_state = CREDIT_STATE_ERROR;
        return;
      end
      remaining = deadline - $time;
      fork
        return_available.wait_trigger();
        begin #(remaining); end
        begin
          wait(!cfg.is_master || i2c_event_pool::reset_epoch != credit_epoch);
        end
      join_any
      disable fork;
    end

    credit_state = CREDIT_STATE_ACTIVE;
    dispatch_ok = 1;
  endtask

  function bit apply_credit_return(i2c_credit_event_payload payload);
    if (payload == null) begin
      `uvm_error("CBT_DRV", "Rejected null credit RETURN")
      return 0;
    end
    if (payload.frame_type != I2C_CREDIT_FRAME_RETURN) begin
      `uvm_error("CBT_DRV", "Rejected wrong-type credit RETURN")
      return 0;
    end
    return receive_credit(payload.credit_count);
  endfunction

  // Drain even when positive credit remains, including while the sequencer is
  // idle. INIT is a one-shot grant in this session, never an additive update.
  function bit drain_credit_channels();
    i2c_credit_event_payload payload;
    bit valid;
    valid = 1;
    if (credit_epoch != i2c_event_pool::reset_epoch) begin
      credit_counter = 0;
      init_complete = 0;
      credit_state = CREDIT_STATE_ERROR;
      return 0;
    end
    while (i2c_event_pool::try_get_credit_init(I2C_CREDIT_CONSUMER_CBT, payload)) begin
      `uvm_error("CBT_DRV", "Rejected duplicate INIT in an already established session")
      valid = 0;
    end
    while (i2c_event_pool::try_get_credit_return(I2C_CREDIT_CONSUMER_CBT, payload)) begin
      if (!apply_credit_return(payload)) valid = 0;
    end
    if (!valid) credit_state = CREDIT_STATE_ERROR;
    return valid;
  endfunction

  // Apply one decoded return atomically.  The producer supplies the explicit
  // count in the event payload; this function never emits a second event.
  function bit receive_credit(int unsigned count = 1);
    longint unsigned already_returned;
    if (!init_complete || credit_epoch != i2c_event_pool::reset_epoch ||
        cfg.cbr_depth == 0 || cfg.cbr_depth > I2C_CREDIT_MAX_DEPTH ||
        count == 0 || count > I2C_CREDIT_MAX_DEPTH || count > cfg.cbr_depth ||
        credit_counter < 0 || credit_counter > int'(cfg.cbr_depth)) begin
      `uvm_error("CBT_DRV", "Rejected credit return outside the initialized bounded budget")
      return 0;
    end
    already_returned = total_credits_received - cfg.cbr_depth;
    if (total_credits_received < cfg.cbr_depth ||
        already_returned > total_data_sent ||
        count > total_data_sent - already_returned ||
        count > cfg.cbr_depth - int'(credit_counter)) begin
      `uvm_error("CBT_DRV", $sformatf(
        "Rejected credit return: count=%0d current=%0d depth=%0d",
        count, credit_counter, cfg.cbr_depth))
      return 0;
    end

    credit_counter += count;
    total_credits_received += count;
    update_credit_state();
    `uvm_info("CBT_DRV", $sformatf("Credit returned (+%0d), total: %0d", count, credit_counter), UVM_HIGH)
    return 1;
  endfunction

  function void update_credit_state();
    if (credit_counter <= 0)
      credit_state = CREDIT_STATE_EXHAUSTED;
    else if (credit_counter >= int'(cfg.cbr_depth))
      credit_state = CREDIT_STATE_READY;
    else
      credit_state = CREDIT_STATE_ACTIVE;
  endfunction

  function void report_phase(uvm_phase phase);
    if (cfg.credit_mode_enable) begin
      `uvm_info("CBT_DRV", $sformatf(
        "CBT Stats: sent=%0d stalls=%0d credits_rcvd=%0d final_counter=%0d",
        total_data_sent, total_stall_cycles, total_credits_received, credit_counter), UVM_LOW)
    end
  endfunction

endclass

`endif // I2C_CREDIT_MASTER_DRIVER_SV
