  localparam I2C_CREDIT_FRAME_DATA = 0, I2C_CREDIT_FRAME_INIT = 1;
  localparam I2C_CREDIT_FRAME_RETURN = 2, I2C_CREDIT_FRAME_STATUS = 3;
  localparam I2C_CREDIT_FRAME_TYPE_MSB = 7, I2C_CREDIT_FRAME_TYPE_LSB = 6;
  localparam I2C_CREDIT_PAYLOAD_MSB = 5, I2C_CREDIT_PAYLOAD_LSB = 0;
  localparam I2C_WRITE = 0, I2C_ADDR_7BIT = 0;
  bit [7:0] data[];
  integer frame_type = I2C_CREDIT_FRAME_DATA;
  integer unsigned credit_count = 0;
  bit is_credit_init = 0, is_credit_return = 0;
  integer direction = I2C_WRITE, addr_mode = I2C_ADDR_7BIT;
  integer addr = 7'h55, item_frame_id = 0, accepted_data_bytes = 0;
  integer target_addr = 7'h55, cfg_depth = 8, cfg_pipe_delay = 1;
  integer num_frames = 5, burst_count = 2, burst_size = 3;
  integer starts = 0, finishes = 0, outstanding = 0;
  integer data_finishes = 0, control_finishes = 0;
  bit [7:0] last_finished_data [0:127];
  integer last_finished_size = 0;

  task automatic reset_item();
    data = new[0];
    frame_type = I2C_CREDIT_FRAME_DATA;
    credit_count = 0;
    is_credit_init = 0;
    is_credit_return = 0;
    accepted_data_bytes = 0;
  endtask

  task automatic start_item(input integer unused_handle);
    if (outstanding != 0) $fatal(1, "Sequencer grant leaked across start_item");
    if (!valid_credit_encoding()) $fatal(1, "Malformed encoding reached start_item");
    starts = starts + 1;
    outstanding = 1;
  endtask

  task automatic finish_item(input integer unused_handle);
    if (outstanding != 1) $fatal(1, "finish_item has no matching grant");
    if (!valid_credit_encoding()) $fatal(1, "Malformed encoding reached finish_item");
    finishes = finishes + 1;
    outstanding = 0;
    last_finished_size = data.size();
    foreach (data[i]) last_finished_data[i] = data[i];
    if (frame_type == I2C_CREDIT_FRAME_DATA) data_finishes = data_finishes + 1;
    else control_finishes = control_finishes + 1;
  endtask
