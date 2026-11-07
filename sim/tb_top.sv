`timescale 1ns/1ps

module tb_top;
  import uvm_pkg::*;
  import i2c_test_pkg::*;

  localparam bit [6:0] DUT_SLAVE_ADDR = 7'h55;

  reg clk;
  reg rst_n;
  
  // Standard Slave signals
  wire slv_scl_o, slv_sda_o, slv_scl_oe, slv_sda_oe;
  
  // RTL Master signals
  wire mst_scl_o, mst_sda_o, mst_scl_oe, mst_sda_oe;
  reg  mst_req;
  reg  mst_rw;
  reg  [6:0] mst_addr;
  reg  [7:0] mst_data;
  wire mst_done;
  wire mst_ack_error;

  // Credit Slave signals
  wire cslv_scl_o, cslv_sda_o, cslv_scl_oe, cslv_sda_oe;
  wire [7:0] credit_counter_obs, fifo_occ_obs;
  wire credit_init_done_obs, fifo_full_obs, fifo_empty_obs;

  // ---- Config-driven DUT mux ----
  bit credit_mode_active = 0;
  initial begin
    if ($test$plusargs("CREDIT_MODE"))
      credit_mode_active = 1;
  end

  i2c_if intf();

  pullup(intf.scl);
  pullup(intf.sda);

  // Standard Slave DUT (always instantiated, only drives when NOT credit mode)
  i2c_slave #(
    .SLAVE_ADDR(DUT_SLAVE_ADDR)
  ) dut_slave (
    .scl_i(intf.scl), 
    .sda_i(intf.sda),
    .scl_o(slv_scl_o),    
    .sda_o(slv_sda_o),
    .scl_oe(slv_scl_oe),
    .sda_oe(slv_sda_oe),
    .rst_n(rst_n)      
  );

  // Credit Slave DUT (always instantiated, only drives when IN credit mode)
  i2c_credit_slave #(
    .SLAVE_ADDR(DUT_SLAVE_ADDR),
    .FIFO_DEPTH(8),
    .PIPE_DELAY(2)
  ) dut_credit_slave (
    .scl_i(intf.scl),
    .sda_i(intf.sda),
    .scl_o(cslv_scl_o),
    .sda_o(cslv_sda_o),
    .scl_oe(cslv_scl_oe),
    .sda_oe(cslv_sda_oe),
    .rst_n(rst_n),
    .credit_counter(credit_counter_obs),
    .fifo_occupancy(fifo_occ_obs),
    .credit_init_done(credit_init_done_obs),
    .fifo_full(fifo_full_obs),
    .fifo_empty(fifo_empty_obs)
  );
  
  // RTL Master DUT (for slave-mode tests)
  i2c_master #(
    .CLK_DIV(50)
  ) dut_master (
    .clk(clk),
    .rst_n(rst_n),
    .req_i(mst_req),
    .rw_i(mst_rw),
    .addr_i(mst_addr),
    .data_in(mst_data),
    .data_out(),
    .done_o(mst_done),
    .ack_error_o(mst_ack_error),
    .scl_i(intf.scl),
    .sda_i(intf.sda),
    .scl_o(mst_scl_o),
    .sda_o(mst_sda_o),
    .scl_oe(mst_scl_oe),
    .sda_oe(mst_sda_oe)
  );

  // ---- Tri-state Driver Logic with DUT Mux ----

  // Standard Slave -- only active when NOT in credit mode
  assign intf.scl = (!credit_mode_active && slv_scl_oe && !slv_scl_o) ? 1'b0 : 1'bz;
  assign intf.sda = (!credit_mode_active && slv_sda_oe && !slv_sda_o) ? 1'b0 : 1'bz;

  // Credit Slave -- only active when IN credit mode
  assign intf.scl = (credit_mode_active && cslv_scl_oe && !cslv_scl_o) ? 1'b0 : 1'bz;
  assign intf.sda = (credit_mode_active && cslv_sda_oe && !cslv_sda_o) ? 1'b0 : 1'bz;

  // The auxiliary RTL master is excluded from credit-mode runs so that the
  // credit evidence has one controller on the bus.
  assign intf.scl = (!credit_mode_active && mst_scl_oe && !mst_scl_o) ? 1'b0 : 1'bz;
  assign intf.sda = (!credit_mode_active && mst_sda_oe && !mst_sda_o) ? 1'b0 : 1'bz;

  // Clock Generation
  initial begin
    clk = 0;
    forever #10 clk = ~clk;
  end

  // Test Control
  initial begin
    rst_n = 0;
    mst_req = 0;
    mst_rw = 0;
    mst_addr = DUT_SLAVE_ADDR;
    mst_data = 8'h00;
    
    #100;
    rst_n = 1;
    #100;
    
    #1000;
    rst_n = 0;
    #100;
    rst_n = 1;
    #100;
    
    #10000000;
    
    if (credit_mode_active) begin
      $display("TB_TOP: Auxiliary RTL master disabled in credit mode.");
    end else begin
      $display("TB_TOP: Triggering RTL Master Sequence...");

      repeat(100) begin
        @(posedge clk);
        mst_req = 1;
        mst_rw = $random % 2;
        mst_data = $random;

        case ($random % 20)
          0: mst_addr = ~DUT_SLAVE_ADDR;
          1: mst_addr = 7'h00;
          2: mst_addr = 7'h7F;
          3: mst_addr = $random;
          default: mst_addr = DUT_SLAVE_ADDR;
        endcase

        #5000;
        mst_req = 0;
        @(posedge mst_done);
        #50000;
      end
    end
  end

  // Connect Interface and Configuration to UVM DB
  initial begin
    uvm_config_db#(virtual i2c_if)::set(null, "*", "vif", intf);
    uvm_config_db#(bit[6:0])::set(null, "*", "slave_addr", DUT_SLAVE_ADDR);
    run_test();
  end

  // Optional vendor waveform dump. Enable +define+I2C_ENABLE_FSDB and link
  // the vendor dumper when compiling with a simulator that provides it.
`ifdef I2C_ENABLE_FSDB
  initial begin
    $fsdbDumpfile("waves.fsdb");
    $fsdbDumpvars(0, tb_top);
  end
`endif

endmodule
