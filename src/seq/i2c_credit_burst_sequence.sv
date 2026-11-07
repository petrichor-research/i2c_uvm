`ifndef I2C_CREDIT_BURST_SEQUENCE_SV
`define I2C_CREDIT_BURST_SEQUENCE_SV

class i2c_credit_burst_sequence extends i2c_credit_base_sequence;
  `uvm_object_utils(i2c_credit_burst_sequence)

  rand int unsigned burst_count;
  rand int unsigned burst_size;

  constraint c_burst {
    burst_count inside {[2:20]};
    burst_size inside {[1:16]};
  }

  function new(string name = "i2c_credit_burst_sequence");
    super.new(name);
  endfunction

  task body();
    bit [7:0] payload[];

    super.pre_body();
    `uvm_info("CREDIT_BURST_SEQ", $sformatf(
      "Burst sequence: %0d bursts of %0d frames each", burst_count, burst_size), UVM_LOW)

    repeat (burst_count) begin
      repeat (burst_size) begin
        payload = new[1];
        foreach (payload[i]) payload[i] = $urandom_range(0, 63);
        send_data_frame(payload);
      end

      #(cfg.cbr_pipe_delay * 1000ns);
      `uvm_info("CREDIT_BURST_SEQ", "Inter-burst gap complete", UVM_HIGH)
    end
  endtask
endclass

class i2c_credit_exhaustion_sequence extends i2c_credit_base_sequence;
  `uvm_object_utils(i2c_credit_exhaustion_sequence)

  function new(string name = "i2c_credit_exhaustion_sequence");
    super.new(name);
  endfunction

  task body();
    bit [7:0] payload[];
    int depth;

    super.pre_body();
    depth = cfg.cbr_depth;

    `uvm_info("CREDIT_EXHAUST_SEQ", $sformatf(
      "Exhaustion sequence: sending %0d frames to drain all credits", depth), UVM_LOW)

    repeat (depth) begin
      payload = new[1];
      payload[0] = $urandom_range(0, 63);
      send_data_frame(payload);
    end

    `uvm_info("CREDIT_EXHAUST_SEQ", "All credits should be exhausted now", UVM_LOW)

    #(cfg.cbr_pipe_delay * 2 * 1000ns);

    `uvm_info("CREDIT_EXHAUST_SEQ", "Sending post-recovery frames", UVM_LOW)
    repeat (depth / 2) begin
      payload = new[1];
      payload[0] = $urandom_range(0, 63);
      send_data_frame(payload);
    end
  endtask
endclass

`endif // I2C_CREDIT_BURST_SEQUENCE_SV
