`ifndef I2C_CREDIT_BASE_SEQUENCE_SV
`define I2C_CREDIT_BASE_SEQUENCE_SV

class i2c_credit_base_sequence extends uvm_sequence #(i2c_transaction);
  `uvm_object_utils(i2c_credit_base_sequence)

  bit [6:0] target_addr = 7'h55;
  i2c_config cfg;

  function new(string name = "i2c_credit_base_sequence");
    super.new(name);
  endfunction

  task pre_body();
    if (cfg == null)
      `uvm_fatal("CREDIT_SEQ", "Sequence configuration must be assigned directly by the test")
  endtask

  task send_data_frame(bit [7:0] payload[], int frame_id = 0);
    i2c_transaction tr;
    tr = i2c_transaction::type_id::create("credit_data_tr");
    tr.direction = I2C_WRITE;
    tr.addr_mode = I2C_ADDR_7BIT;
    tr.addr = target_addr;
    tr.frame_type = I2C_CREDIT_FRAME_DATA;
    tr.frame_id = frame_id;
    tr.data = payload;
    // Validate before acquiring a sequencer grant: an encoding failure must
    // neither submit a malformed item nor leave start_item/finish_item split.
    if (!tr.encode_credit_header()) return;
    start_item(tr);
    finish_item(tr);
  endtask

  task body();
    `uvm_info("CREDIT_SEQ", "Base credit sequence (override in subclass)", UVM_HIGH)
  endtask
endclass

class i2c_credit_init_sequence extends i2c_credit_base_sequence;
  `uvm_object_utils(i2c_credit_init_sequence)

  function new(string name = "i2c_credit_init_sequence");
    super.new(name);
  endfunction

  task body();
    i2c_transaction tr;
    int init_count;

    super.pre_body();
    init_count = cfg.cbr_depth;

    `uvm_info("CREDIT_INIT_SEQ", $sformatf("Initializing %0d credits", init_count), UVM_LOW)

    tr = i2c_transaction::type_id::create("credit_init_tr");
    tr.direction = I2C_WRITE;
    tr.addr_mode = I2C_ADDR_7BIT;
    tr.addr = target_addr;
    tr.frame_type = I2C_CREDIT_FRAME_INIT;
    tr.credit_count = init_count;
    tr.is_credit_init = 1;
    if (!tr.encode_credit_header()) return;
    start_item(tr);
    finish_item(tr);

    `uvm_info("CREDIT_INIT_SEQ", "Credit init sequence complete", UVM_LOW)
  endtask
endclass

class i2c_credit_data_sequence extends i2c_credit_base_sequence;
  `uvm_object_utils(i2c_credit_data_sequence)

  rand int unsigned num_frames;

  constraint c_num_frames {
    num_frames inside {[1:32]};
  }

  function new(string name = "i2c_credit_data_sequence");
    super.new(name);
  endfunction

  task body();
    bit [7:0] payload[];

    super.pre_body();
    `uvm_info("CREDIT_DATA_SEQ", $sformatf("Sending %0d data frames", num_frames), UVM_LOW)

    repeat (num_frames) begin
      // Physical-capacity tests use one FIFO byte per DATA transaction.  This
      // keeps the reservation, ACK commit, and RTL occupancy units identical.
      payload = new[1];
      foreach (payload[i]) payload[i] = $urandom_range(0, 63);
      send_data_frame(payload);
    end
  endtask
endclass

`endif // I2C_CREDIT_BASE_SEQUENCE_SV
