`ifndef I2C_CREDIT_TYPES_SV
`define I2C_CREDIT_TYPES_SV

// Credit Protocol Frame Types
typedef enum bit [1:0] {
  I2C_CREDIT_FRAME_DATA   = 2'b00,
  I2C_CREDIT_FRAME_INIT   = 2'b01,
  I2C_CREDIT_FRAME_RETURN = 2'b10,
  I2C_CREDIT_FRAME_STATUS = 2'b11
} i2c_credit_frame_e;

// Credit Protocol States
typedef enum bit [2:0] {
  CREDIT_STATE_RESET      = 3'b000,
  CREDIT_STATE_INIT       = 3'b001,
  CREDIT_STATE_READY      = 3'b010,
  CREDIT_STATE_ACTIVE     = 3'b011,
  CREDIT_STATE_EXHAUSTED  = 3'b100,
  CREDIT_STATE_ERROR      = 3'b101
} i2c_credit_state_e;

// Credit Error Types (for monitor/scoreboard error injection and detection)
typedef enum bit [2:0] {
  CREDIT_ERR_NONE         = 3'b000,
  CREDIT_ERR_UNDERFLOW    = 3'b001,
  CREDIT_ERR_OVERFLOW     = 3'b010,
  CREDIT_ERR_INIT_MISSING = 3'b011,
  CREDIT_ERR_PHANTOM      = 3'b100,
  CREDIT_ERR_TIMEOUT      = 3'b101
} i2c_credit_error_e;

// Independent consumers of the persistent credit-event channels.  Each
// consumer receives its own queue entry, so one checker cannot consume an
// event intended for the driver (or vice versa).
typedef enum bit {
  I2C_CREDIT_CONSUMER_CBT     = 1'b0,
  I2C_CREDIT_CONSUMER_MONITOR = 1'b1
} i2c_credit_consumer_e;

// Credit protocol constants
parameter int I2C_CREDIT_DEFAULT_DEPTH    = 8;
parameter int I2C_CREDIT_MAX_DEPTH        = 256;
parameter int I2C_CREDIT_DEFAULT_PIPE_DLY = 2;

// Credit frame encoding: first data byte encodes the frame type
// [7:6] = frame_type, [5:0] = payload (credit count or frame_id)
parameter int I2C_CREDIT_FRAME_TYPE_MSB = 7;
parameter int I2C_CREDIT_FRAME_TYPE_LSB = 6;
parameter int I2C_CREDIT_PAYLOAD_MSB    = 5;
parameter int I2C_CREDIT_PAYLOAD_LSB    = 0;

// Typed event payload used by the event-mode credit model.  INIT and RETURN
// publishers must provide an explicit nonzero count; consumers validate the
// frame type and, for INIT, the advertised depth against their configuration.
// physical_release_observed is intentionally false in the current integrated
// master-mode model because no physical FIFO-pop observation is connected.
class i2c_credit_event_payload extends uvm_object;
  i2c_credit_frame_e frame_type;
  int unsigned credit_count;
  bit physical_release_observed;

  `uvm_object_utils_begin(i2c_credit_event_payload)
    `uvm_field_enum(i2c_credit_frame_e, frame_type, UVM_ALL_ON)
    `uvm_field_int(credit_count, UVM_ALL_ON)
    `uvm_field_int(physical_release_observed, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "i2c_credit_event_payload");
    super.new(name);
    frame_type = I2C_CREDIT_FRAME_DATA;
    credit_count = 0;
    physical_release_observed = 0;
  endfunction
endclass

`endif // I2C_CREDIT_TYPES_SV
