`timescale 1ns/1ps

// Isolated functional clocks, not an I2C electrical/timing conformance test.
module tb_credit_fifo;
  localparam integer DEPTH = 8;
  reg rst_n = 1;
  reg scl_release = 1;
  reg sda_release = 1;
  tri1 scl, sda;
  wire scl_o, scl_oe, sda_o, sda_oe;
  wire [7:0] credits, occupancy;
  wire init_done, full, empty;

  assign scl = scl_release ? 1'bz : 1'b0;
  assign sda = sda_release ? 1'bz : 1'b0;
  assign scl = (scl_oe && !scl_o) ? 1'b0 : 1'bz;
  assign sda = (sda_oe && !sda_o) ? 1'b0 : 1'bz;

  // PIPE_DELAY=0 selects the supported no-autonomous-release configuration.
  i2c_credit_slave #(.FIFO_DEPTH(DEPTH), .PIPE_DELAY(0)) dut (
    .scl_i(scl), .sda_i(sda), .scl_o(scl_o), .sda_o(sda_o),
    .scl_oe(scl_oe), .sda_oe(sda_oe), .rst_n(rst_n),
    .credit_counter(credits), .fifo_occupancy(occupancy),
    .credit_init_done(init_done), .fifo_full(full), .fifo_empty(empty)
  );

  always @(posedge scl or negedge scl or negedge rst_n) begin
    #1;
    if (rst_n) begin
      if (int'(occupancy) > DEPTH || int'(credits) > DEPTH ||
          int'(credits) + int'(occupancy) != DEPTH)
        $fatal(1, "capacity mismatch: occupancy=%0d credits=%0d", occupancy, credits);
    end
  end

  task check_occupancy(input integer expected, input string context_name);
    begin
      #1;
      if (occupancy !== 8'(expected) || credits !== 8'(DEPTH - expected) ||
          full !== (expected == DEPTH) || empty !== (expected == 0))
        $fatal(1, "%s: occupancy=%0d credits=%0d full=%b empty=%b expected=%0d",
               context_name, occupancy, credits, full, empty, expected);
    end
  endtask

  task reset_endpoint;
    begin
      rst_n = 0;
      scl_release = 1;
      sda_release = 1;
      #20;
      rst_n = 1;
      #20;
      check_occupancy(0, "reset");
      if (init_done !== 0) $fatal(1, "reset did not clear INIT observation");
    end
  endtask

  task start_condition;
    begin
      sda_release = 1;
      scl_release = 1;
      #10;
      sda_release = 0;
      #10;
      scl_release = 0;
      #10;
    end
  endtask

  task stop_condition;
    begin
      scl_release = 0;
      sda_release = 0;
      #10;
      scl_release = 1;
      #10;
      sda_release = 1;
      #10;
    end
  endtask

  task write_bits(input reg [7:0] value);
    integer bit_index;
    begin
      for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
        sda_release = value[bit_index];
        #10;
        scl_release = 1;
        #10;
        scl_release = 0;
        #10;
      end
    end
  endtask

  task sample_ack(input bit expected_ack);
    reg ack;
    begin
      sda_release = 1;
      #10;
      scl_release = 1;
      #5;
      ack = !sda;
      if (ack !== expected_ack)
        $fatal(1, "ACK mismatch: actual=%b expected=%b", ack, expected_ack);
      #5;
      scl_release = 0;
      #10;
    end
  endtask

  task write_byte(input reg [7:0] value, input bit expected_ack);
    begin
      write_bits(value);
      sample_ack(expected_ack);
    end
  endtask

  task send_write(input reg [7:0] value, input bit expected_ack);
    begin
      start_condition;
      write_byte(8'haa, 1);
      write_byte(value, expected_ack);
      stop_condition;
    end
  endtask

  task read_byte(input reg [7:0] expected, input bit continue_read);
    integer bit_index;
    reg [7:0] actual;
    begin
      sda_release = 1;
      for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
        #10;
        scl_release = 1;
        #5;
        actual[bit_index] = sda;
        #5;
        scl_release = 0;
        #10;
      end
      if (actual !== expected)
        $fatal(1, "FIFO ordering mismatch: actual=%h expected=%h", actual, expected);
      sda_release = !continue_read;
      #10;
      scl_release = 1;
      #10;
      scl_release = 0;
      #10;
      sda_release = 1;
    end
  endtask

  integer index;
  initial begin
    reset_endpoint;

    send_write(8'h07, 1);
    check_occupancy(1, "matched address write");
    start_condition;
    write_byte(8'ha8, 0); // Wrong target address must neither accept nor release.
    write_byte(8'h08, 0);
    stop_condition;
    check_occupancy(1, "unaddressed traffic");
    send_write(8'h48, 1); // INIT is control, not FIFO payload.
    if (init_done !== 1) $fatal(1, "clocked INIT ACK was not observed");
    send_write(8'h85, 1); // RETURN/STATUS no-enqueue handling only; no transported-credit semantics.
    send_write(8'hc5, 1);
    check_occupancy(1, "control frames");
    for (index = 0; index < 16; index = index + 1) begin
      scl_release = 0;
      #10;
      scl_release = 1;
      #10;
    end
    check_occupancy(1, "idle clocks must not release storage");

    reset_endpoint;
    for (index = 1; index <= DEPTH; index = index + 1) begin
      send_write(8'(index), 1);
      check_occupancy(index, "FIFO fill");
    end
    send_write(8'h09, 0);
    check_occupancy(DEPTH, "ninth DATA NACK");

    start_condition;
    write_byte(8'hab, 1);
    read_byte(8'h01, 1);
    check_occupancy(7, "first read ACK");
    read_byte(8'h02, 1);
    check_occupancy(6, "second read ACK");
    read_byte(8'h03, 0);
    check_occupancy(5, "third distinct byte final NACK");
    stop_condition;
    check_occupancy(5, "STOP must not retire another entry");

    for (index = 9; index <= 11; index = index + 1)
      send_write(8'(index), 1);
    check_occupancy(DEPTH, "write pointer wraparound");
    start_condition;
    write_byte(8'hab, 1);
    for (index = 4; index <= 11; index = index + 1)
      read_byte(8'(index), index != 11);
    stop_condition;
    check_occupancy(0, "ordered wrapped FIFO drain");
    start_condition;
    write_byte(8'hab, 1);
    read_byte(8'hff, 0);
    stop_condition;
    check_occupancy(0, "empty read must not underflow");

    reset_endpoint;
    start_condition;
    write_byte(8'haa, 1);
    write_bits(8'h05); // Deliberately withhold the ninth (ACK) clock.
    check_occupancy(0, "unclocked DATA ACK must not commit");
    if (dut.wr_ptr !== 0) $fatal(1, "unclocked ACK advanced write pointer");
    reset_endpoint; // Abort the suspended transfer and discard its staged byte.
    send_write(8'h06, 1);
    start_condition;
    write_byte(8'hab, 1);
    read_byte(8'h06, 0);
    stop_condition;
    check_occupancy(0, "reset discarded staged DATA");

    reset_endpoint;
    start_condition;
    write_byte(8'haa, 1);
    write_bits(8'h48);
    if (init_done !== 0) $fatal(1, "unclocked INIT ACK committed early");
    reset_endpoint;
    $display("PASS tb_credit_fifo: address, controls, fill/NACK, ACK commit, distinct reads, wraparound, reset, and capacity bounds");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "credit FIFO test timed out");
  end
endmodule
