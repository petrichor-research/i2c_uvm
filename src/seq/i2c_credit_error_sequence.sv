`ifndef I2C_CREDIT_ERROR_SEQUENCE_SV
`define I2C_CREDIT_ERROR_SEQUENCE_SV

class i2c_credit_error_sequence extends i2c_credit_base_sequence;
  `uvm_object_utils(i2c_credit_error_sequence)

  typedef enum {
    ERR_SEND_WITHOUT_CREDIT,
    ERR_PHANTOM_CREDIT,
    ERR_INIT_GLITCH,
    ERR_RANDOM_MIX
  } error_scenario_e;

  error_scenario_e scenario;

  function new(string name = "i2c_credit_error_sequence");
    super.new(name);
    scenario = ERR_RANDOM_MIX;
  endfunction

  task body();
    super.pre_body();

    case (scenario)
      ERR_SEND_WITHOUT_CREDIT: run_send_without_credit();
      ERR_PHANTOM_CREDIT:      run_phantom_credit();
      ERR_INIT_GLITCH:         run_init_glitch();
      ERR_RANDOM_MIX:          run_random_mix();
    endcase
  endtask

  task run_send_without_credit();
    bit [7:0] payload[];
    int depth;

    depth = cfg.cbr_depth;
    `uvm_info("CREDIT_ERR_SEQ", $sformatf(
      "Error scenario: send %0d frames beyond credit limit (%0d)",
      depth + 3, depth), UVM_LOW)

    repeat (depth) begin
      payload = new[1];
      payload[0] = $urandom_range(0, 63);
      send_data_frame(payload);
    end

    repeat (3) begin
      payload = new[1];
      // Keep the wire DATA tag valid: this scenario violates the budget,
      // not the six-bit payload encoding.
      payload[0] = 8'h1E;
      send_data_frame(payload);
    end
  endtask

  task run_phantom_credit();
    i2c_transaction tr;
    bit [7:0] payload[];

    `uvm_info("CREDIT_ERR_SEQ", "Error scenario: phantom credit injection", UVM_LOW)

    repeat (cfg.cbr_depth / 2) begin
      payload = new[1];
      payload[0] = $urandom_range(0, 63);
      send_data_frame(payload);
    end

    tr = i2c_transaction::type_id::create("phantom_tr");
    tr.direction = I2C_WRITE;
    tr.addr_mode = I2C_ADDR_7BIT;
    tr.addr = target_addr;
    tr.frame_type = I2C_CREDIT_FRAME_RETURN;
    tr.credit_count = 5;
    tr.is_credit_return = 1;
    if (!tr.encode_credit_header()) return;
    start_item(tr);
    finish_item(tr);
  endtask

  task run_init_glitch();
    bit [7:0] payload[];

    `uvm_info("CREDIT_ERR_SEQ", "Error scenario: init glitch (partial initialization)", UVM_LOW)

    repeat (cfg.cbr_depth) begin
      payload = new[1];
      payload[0] = $urandom_range(0, 63);
      send_data_frame(payload);
    end
  endtask

  task run_random_mix();
    int choice;

    `uvm_info("CREDIT_ERR_SEQ", "Error scenario: random mix", UVM_LOW)

    repeat (5) begin
      choice = $urandom_range(0, 2);
      case (choice)
        0: run_send_without_credit();
        1: run_phantom_credit();
        2: run_init_glitch();
      endcase
      #10us;
    end
  endtask

endclass

`endif // I2C_CREDIT_ERROR_SEQUENCE_SV
