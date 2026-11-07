`timescale 1ns/1ps

module tb;
  // CAPTURE_COMMON
  // SOURCE_TASKS

  bit result_present, serviced, listen_finished;
  bit first_present, first_serviced, second_present, second_serviced;
  integer ack_assertions = 0, before_acks, cases = 0;
  integer first_accepted, first_length;
  reg [7:0] first_data, read_data;
  bit first_restart;

  always @(negedge slave_sda_drive) ack_assertions = ack_assertions + 1;

  initial begin
    #20;

    // An idle role change must cancel listening without a synthetic receive.
    before_acks = ack_assertions;
    fork
      wait_for_request_result(result_present, serviced);
      begin #30; role_is_master = 1; end
    join
    if (result_present || serviced || ack_assertions != before_acks)
      $fatal(1, "Idle role cancellation manufactured service/ACK");
    cases = cases + 1;

    // The same contract applies to an epoch reset while the bus is idle.
    role_is_master = 0;
    fork
      wait_for_request_result(result_present, serviced);
      begin #30; reset_epoch = reset_epoch + 1; end
    join
    if (result_present || serviced || ack_assertions != before_acks)
      $fatal(1, "Idle reset cancellation manufactured service/ACK");
    cases = cases + 1;

    // Matching writes accept every complete byte, and return only at STOP.
    listen_finished = 0;
    fork
      begin
        wait_for_request_result(result_present, serviced);
        listen_finished = 1;
      end
      begin
        #20; wire_start();
        wire_byte(8'hAA); wire_ack(0);
        wire_byte(8'h35); wire_ack(0);
        wire_byte(8'h2A); wire_ack(0);
        #20;
        if (listen_finished) $fatal(1, "Matched write returned before STOP");
        wire_stop();
      end
    join
    if (!result_present || !serviced || captured_length != 2 ||
        captured_accepted_data_bytes != 2 || captured_addr != 7'h55 ||
        captured_direction != I2C_WRITE || captured_data[0] !== 8'h35 ||
        captured_data[1] !== 8'h2A || ack_assertions != before_acks + 3)
      $fatal(1, "Matching multibyte write result mismatch");
    cases = cases + 1;

    // A different seven-bit address receives no ACK and no service result.
    before_acks = ack_assertions;
    fork
      wait_for_request_result(result_present, serviced);
      begin
        #20; wire_start();
        wire_byte(8'hA8); wire_ack(1);
        wire_stop();
      end
    join
    if (result_present || serviced || ack_assertions != before_acks)
      $fatal(1, "Unmatched address manufactured service/ACK");
    cases = cases + 1;

    // A STOP interrupting the address cannot produce an ACK or result handle.
    before_acks = ack_assertions;
    fork
      wait_for_request_result(result_present, serviced);
      begin
        #20; wire_start();
        for (integer i = 2; i >= 0; i = i - 1) begin
          external_sda = (3'b101 >> i) & 1;
          #10; external_scl = 1;
          #10; external_scl = 0;
          #10;
        end
        wire_stop();
      end
    join
    if (result_present || serviced || ack_assertions != before_acks)
      $fatal(1, "Incomplete address manufactured service/ACK");
    cases = cases + 1;

    // Read response ACK then NACK is serviced, but consumes no write credits.
    fork
      wait_for_request_result(result_present, serviced);
      begin
        #20; wire_start();
        wire_byte(8'hAB); wire_ack(0);
        wire_read_byte(read_data);
        if (read_data !== 8'hFF) $fatal(1, "First read response mismatch");
        wire_master_ack(0);
        wire_read_byte(read_data);
        if (read_data !== 8'hFF) $fatal(1, "Second read response mismatch");
        wire_master_ack(1);
        wire_stop();
      end
    join
    if (!result_present || !serviced || captured_length != 2 ||
        captured_accepted_data_bytes != 0 || captured_direction != I2C_READ ||
        !captured_nack_received)
      $fatal(1, "Read ACK/NACK result mismatch");
    cases = cases + 1;

    // Two API calls must preserve the address after a consumed repeated START.
    fork
      begin
        wait_for_request_result(first_present, first_serviced);
        first_accepted = captured_accepted_data_bytes;
        first_length = captured_length;
        first_data = captured_data[0];
        first_restart = captured_repeated_start;
        wait_for_request_result(second_present, second_serviced);
      end
      begin
        #20; wire_start();
        wire_byte(8'hAA); wire_ack(0);
        wire_byte(8'h10); wire_ack(0);
        wire_restart();
        wire_byte(8'hAA); wire_ack(0);
        wire_byte(8'h22); wire_ack(0);
        wire_stop();
      end
    join
    if (!first_present || !first_serviced || !second_present || !second_serviced ||
        first_accepted != 1 || first_length != 1 || first_data !== 8'h10 ||
        !first_restart || captured_accepted_data_bytes != 1 || captured_length != 1 ||
        captured_data[0] !== 8'h22 || captured_repeated_start || slave_restart_pending)
      $fatal(1, "Repeated START did not preserve both slave requests");
    cases = cases + 1;

    $display("PASS slave_receive cases=%0d idle_role/reset_cancel multibyte unmatched short_address read repeated_START", cases);
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "Slave-receive watchdog expired");
  end
endmodule
