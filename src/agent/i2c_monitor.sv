// Update i2c_driver.sv to publish transactions to the monitor's analysis port (via a side channel or direct hook)
// Or better, give the Driver its own analysis port? 
// Standard UVM: Monitor publishes.
// Let's implement a "Cheat" Monitor that spies on the transaction object from the Sequencer/Driver? No.

// Let's implement the Monitor properly (Simplified)
// 1. Wait Start
// 2. Sample 8 bits (Address)
// 3. Sample ACK
// 4. Sample Data Loop
// 5. Wait Stop

// Updated i2c_monitor.sv
`ifndef I2C_MONITOR_SV
`define I2C_MONITOR_SV

class i2c_monitor extends uvm_monitor;
  `uvm_component_utils(i2c_monitor)

  virtual i2c_if vif;
  i2c_config     cfg;
  
  uvm_analysis_port #(i2c_transaction) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  task run_phase(uvm_phase phase);
    fork
      monitor_transactions();
      monitor_bus_idle();
    join
  endtask

  task monitor_transactions();
    i2c_transaction tr;
    logic [7:0] captured_byte;
    logic ack_bit;
    bit start_pending;
    bit boundary_seen;
    bit restart_seen;
    bit address_complete;
    bit reset_seen;
    int unsigned capture_epoch;
    int unsigned start_epoch;
    start_pending = 0;
    start_epoch = i2c_event_pool::reset_epoch;
    
    forever begin
      // 1. Detect START (SDA falling while SCL is high)
      if (start_pending && start_epoch != i2c_event_pool::reset_epoch)
        start_pending = 0;
      if (!start_pending) begin
        @(negedge vif.sda);
        if (vif.scl !== 1'b1) begin
          // Not a protocol START (could be data transition while SCL low)
          continue;
        end
      end
      start_pending = 0;
      i2c_event_pool::trigger_event(i2c_event_pool::START_DETECTED);
      
      tr = i2c_transaction::type_id::create("tr");
      tr.data = new[0]; // Empty dynamic array
      tr.addr_mode = I2C_ADDR_7BIT;
      boundary_seen = 0;
      restart_seen = 0;
      address_complete = 0;
      reset_seen = 0;
      capture_epoch = i2c_event_pool::reset_epoch;

      // Watch boundaries during address and data capture, including malformed
      // short phases.  A byte worker finishing must never end the transaction.
      fork
        begin : watch_boundary
          forever begin
            @(vif.sda);
            if (vif.scl === 1'b1 &&
                (vif.sda === 1'b0 || vif.sda === 1'b1)) begin
              boundary_seen = 1;
              restart_seen = (vif.sda === 1'b0);
              break;
            end
          end
        end
        begin : watch_reset
          wait(i2c_event_pool::reset_epoch != capture_epoch);
          reset_seen = 1;
        end
        begin : sample_frame
          // 2. Decode Address on actual SCL edges, not START's high level.
          sample_byte(captured_byte);
          tr.addr = captured_byte[7:1];
          tr.direction = i2c_direction_e'(captured_byte[0]);
          sample_bit(ack_bit);
          tr.status = (ack_bit === 1'b0) ? I2C_STATUS_OK : I2C_STATUS_ADDR_NACK;
          address_complete = 1;
          if (ack_bit !== 1'b0)
            i2c_event_pool::trigger_event(i2c_event_pool::NACK_RECEIVED);

          // Only sample data if address was ACKed
          if (tr.status == I2C_STATUS_OK) begin
            forever begin
              sample_byte(captured_byte);
              sample_bit(ack_bit);
              // Incomplete bytes or ACK phases interrupted by a boundary are
              // not appended and cannot become accepted receiver capacity.
              tr.data = new[tr.data.size() + 1] (tr.data);
              tr.data[tr.data.size()-1] = captured_byte;
              tr.nack_received = (ack_bit !== 1'b0);
              if (tr.direction == I2C_WRITE && ack_bit === 1'b0)
                tr.accepted_data_bytes++;
              if (ack_bit !== 1'b0) begin
                if (tr.direction == I2C_WRITE)
                  tr.status = I2C_STATUS_DATA_NACK;
                i2c_event_pool::trigger_event(i2c_event_pool::NACK_RECEIVED);
                break;
              end
            end
          end
          // Both address/data NACKs still require STOP or repeated START.
          wait(boundary_seen);
        end
      join_any
      disable fork;

      if (reset_seen || i2c_event_pool::reset_epoch != capture_epoch) begin
        start_pending = 0;
        continue;
      end
      start_pending = restart_seen;
      start_epoch = capture_epoch;
      if (!restart_seen)
        i2c_event_pool::trigger_event(i2c_event_pool::STOP_DETECTED);
      if (!address_complete) continue;
      tr.repeated_start = restart_seen;

      // Credit headers are decoded only after passive bus capture.  The
      // accepted_data_bytes field remains the ACK-qualified write-byte count
      // observed on the bus and is the credit monitor's consumption unit.
      if (tr.direction == I2C_WRITE && tr.data.size() > 0)
        tr.decode_credit_header();
      
      ap.write(tr);
      i2c_event_pool::trigger_event(i2c_event_pool::TRANS_COMPLETE, tr);
    end
  endtask

  // This observer is independent of byte acquisition, so waiting tBUF cannot
  // hide a subsequent START.  Any bus activity cancels the idle indication.
  task monitor_bus_idle();
    int unsigned idle_epoch;
    forever begin
      @(posedge vif.sda);
      if (vif.scl !== 1'b1) continue;
      idle_epoch = i2c_event_pool::reset_epoch;
      fork
        begin
          #(cfg.t_buf_ns * 1ns);
          if (vif.scl === 1'b1 && vif.sda === 1'b1 &&
              i2c_event_pool::reset_epoch == idle_epoch)
            i2c_event_pool::trigger_event(i2c_event_pool::BUS_IDLE);
        end
        begin
          wait(vif.scl !== 1'b1 || vif.sda !== 1'b1 ||
               i2c_event_pool::reset_epoch != idle_epoch);
        end
      join_any
      disable fork;
    end
  endtask
  
  task sample_byte(output logic [7:0] b);
    for(int i=7; i>=0; i--) begin
      @(posedge vif.scl);
      b[i] = vif.sda;
      @(negedge vif.scl);
    end
  endtask
  
  task sample_bit(output logic b);
      @(posedge vif.scl);
      b = vif.sda;
      @(negedge vif.scl);
  endtask

endclass

`endif // I2C_MONITOR_SV
