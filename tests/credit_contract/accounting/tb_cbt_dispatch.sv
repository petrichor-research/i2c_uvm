`timescale 1ns/1ps
module tb;
  // CHANNEL_STUBS
  integer credit_counter = 8, credit_state = CREDIT_STATE_READY;
  integer total_data_sent = 0, total_credits_received = 8, total_stall_cycles = 0;
  bit init_complete = 1;
  integer credit_epoch = 0, wait_failure_status = I2C_STATUS_ERROR;
  integer bus_calls = 0, credit_before_drive = 0;
  integer forced_accepted = 2, forced_status = I2C_STATUS_OK, cases = 0;
  time started;
  // SOURCE_METHODS

  // The real dispatch/reservation branches remain source code. Only the bus
  // dependency is stubbed, returning explicitly controlled ACK results.
  task drive_transfer(input integer tr);
    bus_calls++;
    credit_before_drive = credit_counter;
    transaction_accepted_data_bytes[tr] = forced_accepted;
    transaction_status[tr] = forced_status;
  endtask

  task seed_request();
    clear_channels(); credit_counter = 8; credit_state = CREDIT_STATE_READY;
    total_data_sent = 0; total_credits_received = 8; total_stall_cycles = 0;
    init_complete = 1; credit_epoch = reset_epoch; cfg_is_master = 1;
    cfg_inject_send_without_credit = 0; bus_calls = 0;
    forced_accepted = 2; forced_status = I2C_STATUS_OK;
    transaction_direction[1] = I2C_WRITE;
    transaction_frame_type[1] = I2C_CREDIT_FRAME_DATA;
    transaction_credit_count[1] = 0; transaction_size[1] = 2;
    transaction_data[1][0] = 8'h35; transaction_data[1][1] = 8'h2A;
    transaction_status[1] = I2C_STATUS_OK;
    transaction_accepted_data_bytes[1] = 99; transaction_nack_received[1] = 1;
  endtask

  task require_no_drive();
    if (bus_calls != 0 || transaction_status[1] != I2C_STATUS_ERROR ||
        transaction_accepted_data_bytes[1] != 0 || transaction_nack_received[1] ||
        credit_counter != 8 || total_data_sent != 0)
      $fatal(1, "Invalid request drove bus or retained success/ACK state");
    cases++;
  endtask

  initial begin
    seed_request(); transaction_size[1] = 0;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_data[1][0] = 8'h40;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_data[1][1] = 8'h80;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_data[1][1] = 8'hFF;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_direction[1] = I2C_READ;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_frame_type[1] = I2C_CREDIT_FRAME_INIT;
    transaction_size[1] = 1; transaction_data[1][0] = 8'h48;
    transaction_credit_count[1] = 7;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_frame_type[1] = I2C_CREDIT_FRAME_INIT;
    transaction_size[1] = 1; transaction_data[1][0] = 8'h40;
    transaction_credit_count[1] = 64;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_frame_type[1] = I2C_CREDIT_FRAME_RETURN;
    transaction_size[1] = 1; transaction_data[1][0] = 8'h80;
    transaction_credit_count[1] = 0;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_frame_type[1] = I2C_CREDIT_FRAME_INIT;
    transaction_data[1][0] = 8'h48; transaction_credit_count[1] = 8;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); transaction_frame_type[1] = I2C_CREDIT_FRAME_STATUS;
    transaction_direction[1] = I2C_READ; transaction_size[1] = 1;
    transaction_data[1][0] = 8'hC1; transaction_credit_count[1] = 1;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); dispatch_request(1, 0); require_no_drive();
    seed_request(); cfg_is_master = 0;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); init_complete = 0;
    dispatch_request(1, 1); require_no_drive();
    seed_request(); reset_epoch++;
    dispatch_request(1, 1); require_no_drive();

    seed_request(); dispatch_request(1, 1);
    if (bus_calls != 1 || credit_before_drive != 6 || credit_counter != 6 || total_data_sent != 2)
      $fatal(1, "Valid DATA reservation/commit mismatch");
    cases++;
    seed_request(); forced_accepted = 1; forced_status = I2C_STATUS_DATA_NACK;
    dispatch_request(1, 1);
    if (bus_calls != 1 || credit_counter != 7 || total_data_sent != 1)
      $fatal(1, "Partial NACK rollback mismatch");
    cases++;
    seed_request(); forced_accepted = 0; forced_status = I2C_STATUS_ADDR_NACK;
    dispatch_request(1, 1);
    if (bus_calls != 1 || credit_counter != 8 || total_data_sent != 0)
      $fatal(1, "Address NACK rollback mismatch");
    cases++;
    for (integer test_case = 0; test_case < 2; test_case++) begin
      seed_request(); forced_accepted = test_case == 0 ? 3 : 32'hFFFFFFFF;
      dispatch_request(1, 1);
      if (bus_calls != 1 || credit_counter != 0 || init_complete || total_data_sent != 0 ||
          transaction_status[1] != I2C_STATUS_ERROR || transaction_accepted_data_bytes[1] != 0)
        $fatal(1, "Impossible ACK count underflowed rollback or minted credit");
      cases++;
    end
    seed_request(); transaction_frame_type[1] = I2C_CREDIT_FRAME_INIT;
    transaction_size[1] = 1; transaction_data[1][0] = 8'h48;
    transaction_credit_count[1] = 8; forced_accepted = 1;
    dispatch_request(1, 1);
    if (bus_calls != 1 || credit_counter != 8 || total_data_sent != 0)
      $fatal(1, "Control frame consumed DATA budget");
    cases++;
    seed_request(); credit_counter = 0; total_data_sent = 8;
    started = $time; dispatch_request(1, 1);
    if (bus_calls != 0 || $time - started != 100 ||
        transaction_status[1] != I2C_STATUS_TIMEOUT || transaction_accepted_data_bytes[1] != 0)
      $fatal(1, "Timed-out DATA drove bus or retained success");
    cases++;
    seed_request(); credit_counter = 0; total_data_sent = 8;
    fork dispatch_request(1, 1); begin #25; cfg_is_master = 0; end join
    if (bus_calls != 0 || transaction_status[1] != I2C_STATUS_ERROR ||
        transaction_accepted_data_bytes[1] != 0)
      $fatal(1, "Role-cancelled DATA drove bus or retained success");
    cases++;
    $display("PASS cbt_dispatch cases=%0d full_image_gate exact_ERROR_no_drive rollback_bounds", cases);
    $finish;
  end
  initial begin #30000; $fatal(1, "Dispatch watchdog expired"); end
endmodule
