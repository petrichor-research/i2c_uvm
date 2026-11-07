  localparam I2C_WRITE = 0, I2C_READ = 1, I2C_ADDR_7BIT = 0;
  localparam I2C_STATUS_OK = 0, I2C_STATUS_ADDR_NACK = 1, I2C_STATUS_DATA_NACK = 2;
  localparam I2C_STATUS_ERROR = 5;
  localparam I2C_CREDIT_FRAME_INIT = 1, I2C_CREDIT_FRAME_RETURN = 2;
  localparam I2C_CREDIT_FRAME_TYPE_MSB = 7, I2C_CREDIT_FRAME_TYPE_LSB = 6;
  localparam I2C_CREDIT_PAYLOAD_MSB = 5, I2C_CREDIT_PAYLOAD_LSB = 0;
  localparam START_DETECTED = 1, STOP_DETECTED = 2, NACK_RECEIVED = 3;
  localparam TRANS_COMPLETE = 4, BUS_IDLE = 5;
  reg external_scl = 1;
  reg external_sda = 1;
  reg slave_scl_drive = 1;
  reg slave_sda_drive = 1;
  reg receiver_sda_drive = 1;
  wire scl = external_scl & slave_scl_drive;
  wire sda = external_sda & slave_sda_drive & receiver_sda_drive;
  bit role_is_master = 0;
  reg [6:0] listen_address = 7'h55;
  integer reset_epoch = 0;
  bit slave_restart_pending = 0;
  integer slave_restart_epoch = 0;
  integer captured_length = 0;
  reg [7:0] captured_data [0:31];
  integer captured_addr, captured_addr_mode, captured_direction, captured_status;
  integer captured_accepted_data_bytes;
  bit captured_repeated_start, captured_nack_received;
  integer captured_frame_type, captured_credit_count;
  bit captured_is_credit_init, captured_is_credit_return;
  integer publish_count = 0, completion_events = 0;
  integer start_events = 0, stop_events = 0, nack_events = 0, idle_events = 0;
  integer published_length [0:15], published_accepted [0:15], published_status [0:15];
  integer published_direction [0:15], published_address [0:15];
  bit published_restart [0:15];
  reg [7:0] published_data [0:15][0:31];

  // SOURCE_DECODE

  task automatic reset_capture();
    captured_length = 0;
    captured_accepted_data_bytes = 0;
    captured_addr = 0;
    captured_addr_mode = 0;
    captured_direction = 0;
    captured_status = 0;
    captured_repeated_start = 0;
    captured_nack_received = 0;
    captured_frame_type = 0;
    captured_credit_count = 0;
    captured_is_credit_init = 0;
    captured_is_credit_return = 0;
  endtask

  task automatic capture_publish();
    if (publish_count >= 16) $fatal(1, "Capture storage exceeded");
    published_length[publish_count] = captured_length;
    published_accepted[publish_count] = captured_accepted_data_bytes;
    published_status[publish_count] = captured_status;
    published_direction[publish_count] = captured_direction;
    published_address[publish_count] = captured_addr;
    published_restart[publish_count] = captured_repeated_start;
    for (integer i = 0; i < captured_length; i = i + 1)
      published_data[publish_count][i] = captured_data[i];
    publish_count = publish_count + 1;
  endtask

  task automatic record_event(input integer event_id);
    case (event_id)
      START_DETECTED: start_events = start_events + 1;
      STOP_DETECTED: stop_events = stop_events + 1;
      NACK_RECEIVED: nack_events = nack_events + 1;
      TRANS_COMPLETE: completion_events = completion_events + 1;
      BUS_IDLE: idle_events = idle_events + 1;
      default: $fatal(1, "Unhandled source event %0d", event_id);
    endcase
  endtask

  task automatic wire_start();
    external_scl = 1;
    external_sda = 1;
    #10; external_sda = 0;
    #10; external_scl = 0;
    #10;
  endtask

  task automatic wire_restart();
    external_sda = 1;
    #10; external_scl = 1;
    #10; external_sda = 0;
    #10; external_scl = 0;
    #10;
  endtask

  task automatic wire_stop();
    external_sda = 0;
    #10; external_scl = 1;
    #10; external_sda = 1;
    #20;
  endtask

  task automatic wire_byte(input reg [7:0] value);
    for (integer i = 7; i >= 0; i = i - 1) begin
      external_sda = value[i];
      #10; external_scl = 1;
      #10; external_scl = 0;
      #10;
    end
  endtask

  task automatic wire_ack(input bit expected_nack);
    external_sda = 1;
    #10; external_scl = 1;
    #1;
    if (sda !== expected_nack)
      $fatal(1, "ACK mismatch: observed=%b expected_nack=%b", sda, expected_nack);
    #9; external_scl = 0;
    #10;
  endtask

  task automatic observed_ack(input bit nack);
    receiver_sda_drive = nack;
    wire_ack(nack);
    receiver_sda_drive = 1;
  endtask

  task automatic wire_read_byte(output reg [7:0] value);
    external_sda = 1;
    for (integer i = 7; i >= 0; i = i - 1) begin
      #10; external_scl = 1;
      #1; value[i] = sda;
      #9; external_scl = 0;
      #10;
    end
  endtask

  task automatic wire_master_ack(input bit nack);
    external_sda = nack;
    #10; external_scl = 1;
    #10; external_scl = 0;
    #10; external_sda = 1;
  endtask
