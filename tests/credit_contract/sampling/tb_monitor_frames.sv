`timescale 1ns/1ps

module tb;
  // CAPTURE_COMMON
  // SOURCE_TASKS

  integer cases = 0, before_publish, before_idle, idle_baseline;

  initial monitor_transactions();
  initial monitor_bus_idle();

  initial begin
    #20;
    idle_baseline = idle_events;
    // DATA NACK ends byte collection, not transaction boundary observation.
    wire_start();
    wire_byte(8'hAA); observed_ack(0);
    wire_byte(8'h35); observed_ack(1);
    #20;
    if (publish_count != 0 || completion_events != 0 || stop_events != 0)
      $fatal(1, "DATA NACK published before STOP");
    wire_stop();
    if (publish_count != 1 || published_length[0] != 1 || published_accepted[0] != 0 ||
        published_status[0] != I2C_STATUS_DATA_NACK || published_address[0] != 7'h55 ||
        published_direction[0] != I2C_WRITE || published_data[0][0] !== 8'h35 || idle_events != idle_baseline + 1)
      $fatal(1, "DATA NACK frame mismatch: publishes=%0d len=%0d accepted=%0d status=%0d addr=%h dir=%0d data=%h idle=%0d",
             publish_count, published_length[0], published_accepted[0], published_status[0],
             published_address[0], published_direction[0], published_data[0][0], idle_events);
    cases = cases + 1;

    // Address NACK must likewise remain pending until the actual boundary.
    wire_start();
    wire_byte(8'hAA); observed_ack(1);
    #20;
    if (publish_count != 1 || stop_events != 1)
      $fatal(1, "Address NACK published before STOP");
    wire_stop();
    if (publish_count != 2 || published_length[1] != 0 || published_accepted[1] != 0 ||
        published_status[1] != I2C_STATUS_ADDR_NACK || idle_events != idle_baseline + 2)
      $fatal(1, "Address NACK frame result mismatch");
    cases = cases + 1;

    // The repeated-START edge belongs to the next address as well as the prior boundary.
    wire_start();
    wire_byte(8'hAA); observed_ack(0);
    wire_byte(8'h12); observed_ack(0);
    before_idle = idle_events;
    wire_restart();
    if (publish_count != 3 || idle_events != before_idle)
      $fatal(1, "Repeated START boundary/publish mismatch");
    wire_byte(8'hAA); observed_ack(0);
    wire_byte(8'h34); observed_ack(0);
    wire_stop();
    if (publish_count != 4 || published_length[2] != 1 || published_length[3] != 1 ||
        published_accepted[2] != 1 || published_accepted[3] != 1 ||
        !published_restart[2] || published_restart[3] ||
        published_data[2][0] !== 8'h12 || published_data[3][0] !== 8'h34)
      $fatal(1, "Repeated START lost or combined monitor frames");
    cases = cases + 1;

    // A full byte without a completed ACK must not appear as accepted data.
    wire_start();
    wire_byte(8'hAA); observed_ack(0);
    wire_byte(8'h26);
    wire_stop();
    if (publish_count != 5 || published_length[4] != 0 || published_accepted[4] != 0)
      $fatal(1, "Interrupted ACK phase manufactured accepted data");
    cases = cases + 1;

    // An epoch reset during a frame cancels it instead of publishing old data.
    before_publish = publish_count;
    wire_start();
    wire_byte(8'hAA); observed_ack(0);
    wire_byte(8'h18);
    reset_epoch = reset_epoch + 1;
    #20;
    wire_stop();
    if (publish_count != before_publish || completion_events != publish_count)
      $fatal(1, "Reset frame was published or completion events duplicated");
    cases = cases + 1;

    // A malformed address phase is discarded rather than joined to the next frame.
    wire_start();
    for (integer i = 2; i >= 0; i = i - 1) begin
      external_sda = (3'b101 >> i) & 1;
      #10; external_scl = 1;
      #10; external_scl = 0;
      #10;
    end
    wire_stop();
    if (publish_count != before_publish)
      $fatal(1, "Incomplete address was published");
    cases = cases + 1;

    // Any activity before tBUF expires cancels that idle indication; the
    // independent observer must still allow the next complete START/frame.
    before_idle = idle_events;
    external_sda = 0;
    external_scl = 0;
    #10; external_scl = 1;
    #10; external_sda = 1;
    #5; external_scl = 0;
    #20;
    if (idle_events != before_idle)
      $fatal(1, "Short bus-free interval incorrectly emitted BUS_IDLE");
    wire_start();
    wire_byte(8'hAA); observed_ack(0);
    wire_byte(8'h15); observed_ack(0);
    wire_stop();
    if (publish_count != before_publish + 1 || idle_events != before_idle + 1 ||
        published_data[before_publish][0] !== 8'h15)
      $fatal(1, "Cancelled idle observation hid the following START/frame");
    cases = cases + 1;

    $display("PASS monitor_frames cases=%0d NACK_boundaries repeated_START partial_ACK short_address reset_epoch idle_tBUF/cancel", cases);
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "Monitor-frame watchdog expired");
  end
endmodule
