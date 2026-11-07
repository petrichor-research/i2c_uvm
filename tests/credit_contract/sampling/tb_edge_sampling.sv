`timescale 1ns/1ps

// The runner inserts the current repository's monitor and slave byte samplers.
// Stimulus below is independent of those implementations.
module tb;
  reg external_scl = 1;
  reg external_sda = 1;
  reg slave_scl_drive = 1;
  reg slave_sda_drive = 1;
  wire scl = external_scl & slave_scl_drive;
  wire sda = external_sda & slave_sda_drive;
  reg [7:0] monitor_address, monitor_data, slave_address, slave_data;
  reg address_ack, data_ack;
  reg monitor_done = 0;
  reg slave_done = 0;

  // SOURCE_TASKS

  task automatic wire_byte(input reg [7:0] value);
    for (integer i = 7; i >= 0; i = i - 1) begin
      external_sda = value[i];
      #10; external_scl = 1;
      #10; external_scl = 0;
      #10;
    end
  endtask

  task automatic wire_ack();
    external_sda = 0;
    #10; external_scl = 1;
    #10; external_scl = 0;
    #10;
  endtask

  initial begin
    @(negedge sda);
    sample_byte(monitor_address);
    sample_bit(address_ack);
    sample_byte(monitor_data);
    sample_bit(data_ack);
    monitor_done = 1;
  end

  initial begin
    @(negedge sda);
    slave_read_byte(slave_address);
    @(posedge scl);
    @(negedge scl);
    slave_read_byte(slave_data);
    slave_done = 1;
  end

  initial begin
    #20; external_sda = 0;
    #20; external_scl = 0;
    #20;
    wire_byte(8'hAA);  // Address 0x55, WRITE; START must not be a sampled bit.
    wire_ack();
    wire_byte(8'h35);  // Deliberately distinct bit pattern from address and ACK.
    wire_ack();
    external_sda = 0;
    #10; external_scl = 1;
    #10; external_sda = 1;
    #20;
    if (!monitor_done || !slave_done)
      $fatal(1, "Sampler did not finish: monitor=%0b slave=%0b", monitor_done, slave_done);
    if (monitor_address !== 8'hAA || monitor_data !== 8'h35 || address_ack !== 0 || data_ack !== 0)
      $fatal(1, "Monitor misdecode: addr=%h data=%h ACKs=%b%b", monitor_address, monitor_data, address_ack, data_ack);
    if (slave_address !== 8'hAA || slave_data !== 8'h35)
      $fatal(1, "Slave misdecode: addr=%h data=%h", slave_address, slave_data);
    $display("PASS edge_sampling address=AA data=35 monitor_and_slave_aligned=1");
    $finish;
  end

  initial begin
    #5000;
    $fatal(1, "Sampling test watchdog expired");
  end
endmodule
