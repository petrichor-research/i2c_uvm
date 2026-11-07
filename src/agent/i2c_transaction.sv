`ifndef I2C_TRANSACTION_SV
`define I2C_TRANSACTION_SV

class i2c_transaction extends uvm_sequence_item;

  // Randomizable Protocol Fields
  rand i2c_direction_e direction;
  rand bit [9:0]       addr;
  rand i2c_addr_mode_e addr_mode;
  rand bit [7:0]       data[];
  rand bit             repeated_start;

  // Response / Status Fields
  i2c_status_e         status;
  bit                  nack_received;
  int unsigned         accepted_data_bytes;

  // ---- Credit-Layer Metadata ----
  rand i2c_credit_frame_e frame_type;
  int unsigned credit_count;
  int unsigned frame_id;
  bit is_credit_return;
  bit is_credit_init;

  int credit_counter_snapshot;
  i2c_credit_state_e credit_state_snapshot;

  `uvm_object_utils_begin(i2c_transaction)
    `uvm_field_enum(i2c_direction_e, direction, UVM_ALL_ON)
    `uvm_field_int(addr, UVM_ALL_ON)
    `uvm_field_enum(i2c_addr_mode_e, addr_mode, UVM_ALL_ON)
    `uvm_field_array_int(data, UVM_ALL_ON)
    `uvm_field_int(repeated_start, UVM_ALL_ON)
    `uvm_field_enum(i2c_status_e, status, UVM_ALL_ON)
    `uvm_field_int(nack_received, UVM_ALL_ON)
    `uvm_field_int(accepted_data_bytes, UVM_ALL_ON)
    `uvm_field_enum(i2c_credit_frame_e, frame_type, UVM_ALL_ON)
    `uvm_field_int(credit_count,            UVM_ALL_ON)
    `uvm_field_int(frame_id,                UVM_ALL_ON)
    `uvm_field_int(is_credit_return,        UVM_ALL_ON)
    `uvm_field_int(is_credit_init,          UVM_ALL_ON)
    `uvm_field_int(credit_counter_snapshot, UVM_ALL_ON)
    `uvm_field_enum(i2c_credit_state_e, credit_state_snapshot, UVM_ALL_ON)
  `uvm_object_utils_end

  constraint c_data_size_default {
    data.size() inside {[1:128]};
  }

  constraint c_addr_7bit {
    if (addr_mode == I2C_ADDR_7BIT) {
      addr inside {[0:127]};
    }
  }

  constraint c_frame_defaults {
    soft frame_type == I2C_CREDIT_FRAME_DATA;
  }

  function new(string name = "i2c_transaction");
    super.new(name);
    frame_type = I2C_CREDIT_FRAME_DATA;
    credit_count = 0;
    frame_id = 0;
    is_credit_return = 0;
    is_credit_init = 0;
    accepted_data_bytes = 0;
  endfunction

  virtual function string convert2string();
    string s;
    s = "\n--------------------------------------------------\n";
    s = {s, $sformatf(" I2C TRANSACTION\n")};
    s = {s, $sformatf(" Address      : 0x%0x (%s)\n", addr, (addr_mode==I2C_ADDR_7BIT) ? "7-bit" : "10-bit")};
    s = {s, $sformatf(" Direction    : %s\n", direction.name())};
    s = {s, $sformatf(" Payload Size : %0d bytes\n", data.size())};
    if (data.size() > 0) begin
      s = {s, " Data Content :\n"};
      foreach (data[i]) begin
        if (i % 16 == 0) s = {s, $sformatf("    [%04x] ", i)};
        s = {s, $sformatf("%02x ", data[i])};
        if ((i+1) % 16 == 0) s = {s, "\n"};
      end
      if (data.size() % 16 != 0) s = {s, "\n"};
    end
    s = {s, $sformatf(" Status       : %s\n", status.name())};
    s = {s, $sformatf(" ACKed Bytes  : %0d\n", accepted_data_bytes)};
    if (frame_type != I2C_CREDIT_FRAME_DATA) begin
      s = {s, $sformatf(" Credit Frame : %s\n", frame_type.name())};
      s = {s, $sformatf(" Credit Count : %0d\n", credit_count)};
    end
    if (credit_counter_snapshot != 0 || credit_state_snapshot != CREDIT_STATE_RESET)
      s = {s, $sformatf(" Credit State : %s (counter=%0d)\n",
                        credit_state_snapshot.name(), credit_counter_snapshot)};
    s = {s, "--------------------------------------------------"};
    return s;
  endfunction

  // The retained wire convention carries a type tag in every byte. DATA has
  // six payload bits per byte; it does not gain an extra header byte.
  function bit encode_credit_header();
    bit [7:0] header;
    if (frame_type == I2C_CREDIT_FRAME_DATA) begin
      if (data.size() == 0) begin
        `uvm_error("CREDIT_ENCODE", "DATA requires at least one six-bit payload byte")
        return 0;
      end
      foreach (data[i]) begin
        if (data[i][I2C_CREDIT_FRAME_TYPE_MSB:I2C_CREDIT_FRAME_TYPE_LSB] !=
            I2C_CREDIT_FRAME_DATA) begin
          `uvm_error("CREDIT_ENCODE", $sformatf(
            "DATA payload[%0d]=0x%02x is outside the encodable range 0..63", i, data[i]))
          return 0;
        end
      end
      // Valid DATA already has tag 00. Preserve all payload bits and bytes.
      is_credit_init = 0;
      is_credit_return = 0;
      return 1;
    end

    // This six-bit wire field is distinct from event-channel counts, whose
    // separately validated range extends to I2C_CREDIT_MAX_DEPTH.
    if (credit_count == 0 || credit_count > 63 || data.size() > 1) begin
      `uvm_error("CREDIT_ENCODE",
        "Control encoding requires one byte and an explicit count in 1..63")
      return 0;
    end
    header[I2C_CREDIT_FRAME_TYPE_MSB:I2C_CREDIT_FRAME_TYPE_LSB] = frame_type;
    header[I2C_CREDIT_PAYLOAD_MSB:I2C_CREDIT_PAYLOAD_LSB] = credit_count[5:0];
    if (data.size() == 0) data = new[1];
    data[0] = header;
    is_credit_init = (frame_type == I2C_CREDIT_FRAME_INIT);
    is_credit_return = (frame_type == I2C_CREDIT_FRAME_RETURN);
    return 1;
  endfunction

  // Callers receiving an already encoded transaction can validate the whole
  // wire image without re-encoding or silently masking an invalid DATA byte.
  function bit valid_credit_encoding();
    if (data.size() == 0) return 0;
    if (frame_type == I2C_CREDIT_FRAME_DATA) begin
      foreach (data[i]) begin
        if (data[i][I2C_CREDIT_FRAME_TYPE_MSB:I2C_CREDIT_FRAME_TYPE_LSB] !=
            I2C_CREDIT_FRAME_DATA) return 0;
      end
      return 1;
    end
    return data.size() == 1 && credit_count > 0 && credit_count <= 63 &&
           data[0][I2C_CREDIT_FRAME_TYPE_MSB:I2C_CREDIT_FRAME_TYPE_LSB] == frame_type &&
           data[0][I2C_CREDIT_PAYLOAD_MSB:I2C_CREDIT_PAYLOAD_LSB] == credit_count;
  endfunction

  function void decode_credit_header();
    if (data.size() > 0) begin
      frame_type = i2c_credit_frame_e'(data[0][I2C_CREDIT_FRAME_TYPE_MSB:I2C_CREDIT_FRAME_TYPE_LSB]);
      credit_count = data[0][I2C_CREDIT_PAYLOAD_MSB:I2C_CREDIT_PAYLOAD_LSB];
      is_credit_init   = (frame_type == I2C_CREDIT_FRAME_INIT);
      is_credit_return = (frame_type == I2C_CREDIT_FRAME_RETURN);
    end
  endfunction

endclass

`endif // I2C_TRANSACTION_SV
