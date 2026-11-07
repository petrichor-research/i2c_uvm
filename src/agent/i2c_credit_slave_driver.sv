`ifndef I2C_CREDIT_SLAVE_DRIVER_SV
`define I2C_CREDIT_SLAVE_DRIVER_SV

class i2c_credit_slave_driver extends i2c_driver;
  `uvm_component_utils(i2c_credit_slave_driver)

  int credit_counter;
  i2c_credit_state_e credit_state;

  int cr_return_pipe[$];

  longint unsigned total_data_received;
  longint unsigned total_credits_returned;
  longint unsigned total_credits_initialized;
  longint signed conservation_residual;
  bit init_complete;
  int unsigned credit_epoch;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    credit_counter = 0;
    credit_state = CREDIT_STATE_RESET;
    total_data_received = 0;
    total_credits_returned = 0;
    total_credits_initialized = 0;
    init_complete = 0;
    credit_epoch = i2c_event_pool::reset_epoch;
  endfunction

  task run_phase(uvm_phase phase);
    vif.scl_drive <= 1'b1;
    vif.sda_drive <= 1'b1;

    if (!cfg.credit_mode_enable) begin
      super.run_phase(phase);
      return;
    end

    credit_init_task();

    fork
      credit_data_receive_loop();
      credit_return_task();
    join
  endtask

  task credit_init_task();
    i2c_credit_event_payload init_event;
    int unsigned initial_count;
    `uvm_info("CBR_DRV", $sformatf("Starting credit init: depth=%0d", cfg.cbr_depth), UVM_LOW)
    credit_state = CREDIT_STATE_INIT;
    init_complete = 0;
    credit_epoch = i2c_event_pool::reset_epoch;
    credit_counter = 0;
    cr_return_pipe.delete();
    if (cfg.cbr_depth == 0 || cfg.cbr_depth > I2C_CREDIT_MAX_DEPTH) begin
      credit_state = CREDIT_STATE_ERROR;
      `uvm_error("CBR_DRV", "Configured INIT depth is outside the supported event range")
      return;
    end

    if (cfg.inject_init_glitch) begin
      `uvm_info("CBR_DRV", "Injecting init glitch -- skipping partial init", UVM_MEDIUM)
      initial_count = cfg.cbr_depth / 2;
    end else begin
      initial_count = cfg.cbr_depth;
    end

    fork
      begin #(cfg.cbr_depth * cfg.t_low_ns * 1ns); end
      begin wait(i2c_event_pool::reset_epoch != credit_epoch); end
    join_any
    disable fork;
    if (i2c_event_pool::reset_epoch != credit_epoch) begin
      credit_state = CREDIT_STATE_ERROR;
      return;
    end

    init_event = i2c_credit_event_payload::type_id::create("credit_init_event");
    init_event.frame_type = I2C_CREDIT_FRAME_INIT;
    init_event.credit_count = initial_count;
    if (!i2c_event_pool::publish_credit_init(init_event)) begin
      credit_state = CREDIT_STATE_ERROR;
      `uvm_error("CBR_DRV", "Credit INIT payload was rejected by the event channel")
      return;
    end
    credit_counter = initial_count;
    total_credits_initialized = initial_count;
    init_complete = (initial_count == cfg.cbr_depth);
    credit_state = init_complete ? CREDIT_STATE_READY : CREDIT_STATE_ERROR;
    `uvm_info("CBR_DRV", $sformatf("Credit init complete: %0d credits granted", credit_counter), UVM_LOW)
  endtask

  task credit_data_receive_loop();
    forever begin
      if (!cfg.is_master) begin
        i2c_transaction observed;
        bit serviced;
        bit accounted;
        if (!init_complete || credit_epoch != i2c_event_pool::reset_epoch) begin
          invalidate_reset_session();
          #(idle_poll_time);
          continue;
        end
        wait_for_request_result(observed, serviced);
        accounted = account_received_transaction(observed, serviced);
      end else begin
        bit timed_out;
        i2c_event_pool::wait_for_event_timeout(
          i2c_event_pool::ROLE_UPDATE, idle_poll_time, timed_out);
      end
    end
  endtask

  function void invalidate_reset_session();
    if (credit_epoch != i2c_event_pool::reset_epoch) begin
      init_complete = 0;
      credit_counter = 0;
      cr_return_pipe.delete();
      credit_state = CREDIT_STATE_ERROR;
    end
  endfunction

  function bit account_received_transaction(i2c_transaction tr, bit serviced);
    int unsigned accepted;
    invalidate_reset_session();
    if (!serviced || tr == null || cfg.is_master || !init_complete)
      return 0;
    if (tr.direction != I2C_WRITE || tr.frame_type != I2C_CREDIT_FRAME_DATA ||
        tr.status == I2C_STATUS_ADDR_NACK || tr.accepted_data_bytes == 0)
      return 0;
    accepted = tr.accepted_data_bytes;
    if (cfg.cbr_depth == 0 || cfg.cbr_depth > I2C_CREDIT_MAX_DEPTH ||
        !tr.valid_credit_encoding() ||
        accepted > tr.data.size() || accepted > cfg.cbr_depth ||
        credit_counter < 0 || credit_counter > int'(cfg.cbr_depth) ||
        accepted > int'(credit_counter)) begin
      `uvm_error("CBR_DRV", "Rejected inconsistent or over-budget ACK-qualified DATA accounting")
      credit_state = CREDIT_STATE_ERROR;
      return 0;
    end
    credit_counter -= accepted;
    total_data_received += accepted;
    repeat (accepted) cr_return_pipe.push_back(cfg.cbr_pipe_delay);
    credit_state = (credit_counter == 0) ? CREDIT_STATE_EXHAUSTED : CREDIT_STATE_ACTIVE;
    return 1;
  endfunction

  function bit publish_return(int unsigned count, int unsigned expected_epoch);
    i2c_credit_event_payload return_event;
    invalidate_reset_session();
    if (!init_complete || expected_epoch != credit_epoch ||
        credit_epoch != i2c_event_pool::reset_epoch) return 0;
    if (cfg.cbr_depth == 0 || cfg.cbr_depth > I2C_CREDIT_MAX_DEPTH ||
        count == 0 || count > I2C_CREDIT_MAX_DEPTH || count > cfg.cbr_depth ||
        credit_counter < 0 || credit_counter > int'(cfg.cbr_depth) ||
        (!cfg.inject_phantom_credit &&
         (count > cfg.cbr_depth - int'(credit_counter) ||
          total_credits_returned > total_data_received ||
          count > total_data_received - total_credits_returned))) begin
      `uvm_error("CBR_DRV", "Rejected invalid credit RETURN without changing receiver accounting")
      credit_state = CREDIT_STATE_ERROR;
      return 0;
    end
    return_event = i2c_credit_event_payload::type_id::create("credit_return_event");
    return_event.frame_type = I2C_CREDIT_FRAME_RETURN;
    return_event.credit_count = count;
    // This is behavioral pipeline completion, not physical FIFO-pop evidence.
    return_event.physical_release_observed = 0;
    if (!i2c_event_pool::publish_credit_return(return_event)) begin
      credit_state = CREDIT_STATE_ERROR;
      return 0;
    end
    credit_counter += count;
    total_credits_returned += count;
    credit_state = (credit_counter == int'(cfg.cbr_depth)) ?
                   CREDIT_STATE_READY : CREDIT_STATE_ACTIVE;
    return 1;
  endfunction

  task credit_return_task();
    forever begin
      if (cr_return_pipe.size() > 0) begin
        int delay;
        int unsigned return_count;
        int unsigned expected_epoch;
        bit published;
        expected_epoch = credit_epoch;
        delay = cr_return_pipe.pop_front();
        fork
          begin repeat (delay) #(cfg.t_low_ns * 1ns); end
          begin wait(i2c_event_pool::reset_epoch != expected_epoch); end
        join_any
        disable fork;

        return_count = 1;

        if (cfg.inject_phantom_credit &&
            ((total_credits_returned + 1) % 10 == 0)) begin
          return_count++;
          `uvm_info("CBR_DRV", "Injecting phantom credit", UVM_MEDIUM)
        end

        published = publish_return(return_count, expected_epoch);
      end else begin
        invalidate_reset_session();
        #(cfg.t_low_ns * 1ns);
      end
    end
  endtask

  function void check_phase(uvm_phase phase);
    longint signed expected_balance;
    super.check_phase(phase);
    if (cfg.credit_mode_enable) begin
      // Pending accepted bytes may still await behavioral return. This identity
      // checks accounting, not receiver drain or physical-release causality.
      expected_balance = longint'(total_credits_initialized) -
                         longint'(total_data_received) +
                         longint'(total_credits_returned);
      conservation_residual = longint'(credit_counter) - expected_balance;
      if (conservation_residual != 0) begin
        `uvm_error("CBR_DRV", $sformatf(
          "TBI-4 conservation mismatch: credit_counter=%0d expected=%0d delta=%0d (init=%0d rcvd=%0d ret=%0d)",
          credit_counter, expected_balance, conservation_residual,
          total_credits_initialized, total_data_received, total_credits_returned))
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    if (cfg.credit_mode_enable) begin
      `uvm_info("CBR_DRV", $sformatf(
        "CBR Stats: rcvd=%0d returned=%0d init=%0d final_counter=%0d",
        total_data_received, total_credits_returned,
        total_credits_initialized, credit_counter), UVM_LOW)
    end
  endfunction

endclass

`endif // I2C_CREDIT_SLAVE_DRIVER_SV
