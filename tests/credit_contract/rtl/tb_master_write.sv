`timescale 1ns/1ps

module tb_master_write;
  // White-box state encodings from i2c_master; avoid hierarchical enum
  // references that trigger a Verilator 5.052 internal elaboration error.
  localparam [3:0] ST_START = 1, ST_ADDR = 2, ST_ACK_ADDR = 3;
  localparam [3:0] ST_DATA_TX = 4, ST_ACK_DATA_TX = 5;
  reg clk = 0;
  reg rst_n = 1;
  reg request = 0;
  reg [6:0] address = 7'h55;
  reg [7:0] payload = 0;
  reg ack_release = 1;
  tri1 scl, sda;
  wire scl_o, scl_oe, sda_o, sda_oe, done, ack_error;
  reg [7:0] address_seen = 0;
  reg [7:0] payload_seen = 0;
  integer address_bits = 0;
  integer payload_bits = 0;

  assign scl = (scl_oe && !scl_o) ? 1'b0 : 1'bz;
  assign sda = (sda_oe && !sda_o) ? 1'b0 : 1'bz;
  assign sda = ack_release ? 1'bz : 1'b0;

  i2c_master #(.CLK_DIV(2)) dut (
    .clk(clk), .rst_n(rst_n), .req_i(request), .rw_i(1'b0),
    .addr_i(address), .data_in(payload), .data_out(),
    .done_o(done), .ack_error_o(ack_error), .scl_i(scl), .sda_i(sda),
    .scl_o(scl_o), .sda_o(sda_o), .scl_oe(scl_oe), .sda_oe(sda_oe)
  );

  always #5 clk = !clk;
  always @(posedge scl) begin
    if (dut.state == ST_ADDR) begin
      address_seen = {address_seen[6:0], sda};
      address_bits = address_bits + 1;
    end
    if (dut.state == ST_DATA_TX) begin
      payload_seen = {payload_seen[6:0], sda};
      payload_bits = payload_bits + 1;
    end
  end
  always @(negedge scl) begin
    #1;
    ack_release = !(dut.state == ST_ACK_ADDR || dut.state == ST_ACK_DATA_TX);
  end

  task check_write(input reg [6:0] target, input reg [7:0] value);
    begin
      @(negedge clk);
      address = target;
      payload = value;
      address_seen = 0;
      payload_seen = 0;
      address_bits = 0;
      payload_bits = 0;
      request = 1;
      wait (dut.state == ST_START);
      @(negedge clk);
      request = 0;
      @(posedge done);
      #1;
      if (address_bits != 8 || payload_bits != 8 ||
          address_seen !== {target, 1'b0} || payload_seen !== value || ack_error !== 0)
        $fatal(1, "master write mismatch: address=%h/%h payload=%h/%h bits=%0d/%0d ack_error=%b",
               address_seen, {target, 1'b0}, payload_seen, value,
               address_bits, payload_bits, ack_error);
      #200;
    end
  endtask

  initial begin
    #1;
    rst_n = 0;
    #20;
    rst_n = 1;
    #30;
    check_write(7'h55, 8'h00);
    check_write(7'h55, 8'h01);
    check_write(7'h55, 8'h7f);
    check_write(7'h2a, 8'h80);
    check_write(7'h2a, 8'hff);
    $display("PASS tb_master_write: all eight DATA bits match the requested payload across opposite address/data MSBs");
    $finish;
  end

  initial begin
    #50000;
    $fatal(1, "master write test timed out");
  end
endmodule
