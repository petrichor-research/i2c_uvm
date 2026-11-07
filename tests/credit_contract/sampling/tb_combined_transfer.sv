`timescale 1ns/1ps

// The runner inserts current source tasks, including drive_transfer's control
// flow. Only transaction fields are lowered to fixed-size procedural arrays.
module tb;
  localparam I2C_WRITE = 0, I2C_READ = 1;
  localparam I2C_STATUS_OK = 0, I2C_STATUS_ADDR_NACK = 1, I2C_STATUS_DATA_NACK = 2;
  reg scl_drive = 1;
  reg sda_drive = 1;
  reg receiver_sda_drive = 1;
  wire scl = scl_drive;
  wire sda = sda_drive & receiver_sda_drive;
  bit master_restart_pending = 0;
  bit slave_restart_pending = 0;
  integer master_restart_epoch = 0, slave_restart_epoch = 0, reset_epoch = 0;
  reg [9:0] request_addr [0:1];
  reg request_direction [0:1];
  reg [7:0] request_data [0:1][0:1];
  integer request_length [0:1];
  reg request_restart [0:1];
  reg request_nack [0:1];
  integer request_status [0:1];
  integer request_accepted [0:1];
  integer starts = 0, stops = 0, captured_count = 0, bit_count = 0;
  reg observation_enabled = 0;
  reg transaction_active = 0;
  reg [7:0] shift = 0;
  reg [7:0] captured [0:7];

  // SOURCE_TASKS

  // Independent open-drain receiver: ACK each complete address/data byte.
  always @(negedge sda) begin
    if (observation_enabled && scl === 1'b1) begin
      starts = starts + 1;
      transaction_active = 1;
      bit_count = 0;
      shift = 0;
    end
  end

  always @(posedge sda) begin
    if (observation_enabled && scl === 1'b1) begin
      stops = stops + 1;
      transaction_active = 0;
    end
  end

  always @(posedge scl) begin
    if (transaction_active) begin
      if (bit_count == 8) begin
        bit_count = 0;
      end else begin
        shift = {shift[6:0], sda};
        bit_count = bit_count + 1;
        if (bit_count == 8) begin
          captured[captured_count] = shift;
          captured_count = captured_count + 1;
        end
      end
    end
  end

  always @(negedge scl) begin
    receiver_sda_drive <= !(transaction_active && bit_count == 8);
  end

  initial begin
    request_addr[0] = 10'h055;
    request_addr[1] = 10'h055;
    request_direction[0] = I2C_WRITE;
    request_direction[1] = I2C_WRITE;
    request_length[0] = 1;
    request_length[1] = 1;
    request_data[0][0] = 8'h35;
    request_data[1][0] = 8'hCA;
    request_restart[0] = 1;
    request_restart[1] = 0;
    #1; observation_enabled = 1;
    #19;
    drive_transfer(0);
    drive_transfer(1);
    #20;
    if (starts != 2 || stops != 1)
      $fatal(1, "Combined transfer boundaries: START=%0d STOP=%0d, expected 2/1", starts, stops);
    if (captured_count != 4 || captured[0] !== 8'hAA || captured[1] !== 8'h35 ||
        captured[2] !== 8'hAA || captured[3] !== 8'hCA)
      $fatal(1, "Combined transfer bytes: count=%0d values=%h %h %h %h", captured_count,
             captured[0], captured[1], captured[2], captured[3]);
    if (request_accepted[0] != 1 || request_accepted[1] != 1 ||
        request_status[0] != I2C_STATUS_OK || request_status[1] != I2C_STATUS_OK)
      $fatal(1, "Combined transfer ACK accounting failed");
    if (master_restart_pending)
      $fatal(1, "Final STOP did not clear pending repeated START");
    $display("PASS combined_transfer START=2 STOP=1 bytes=AA,35,AA,CA accepted=1,1");
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "Combined-transfer watchdog expired");
  end
endmodule
