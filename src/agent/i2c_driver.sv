`ifndef I2C_DRIVER_SV
`define I2C_DRIVER_SV

class i2c_driver extends uvm_driver #(i2c_transaction);
  `uvm_component_utils(i2c_driver)

  virtual i2c_if vif;
  i2c_config     cfg;
  time           idle_poll_time = 1000ns; // prevents busy-spins when no items are available
  bit            master_restart_pending = 0;
  bit            slave_restart_pending = 0;
  int unsigned   master_restart_epoch = 0;
  int unsigned   slave_restart_epoch = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    // Initialize Bus Drive to High-Z (Released)
    vif.scl_drive <= 1'b1;
    vif.sda_drive <= 1'b1;
    
    forever begin
      // NOTE: cfg.is_master is allowed to change at runtime (dual-role).
      // The driver must therefore avoid indefinitely blocking in MASTER mode
      // when no new items are pending; otherwise role switching requires hacks
      // (e.g., injecting a "dummy" item to unblock get_next_item()).
      if (cfg.is_master) begin
        // --- MASTER MODE ---
        // Non-blocking pull to allow role changes to take effect promptly.
        req = null;
        seq_item_port.try_next_item(req);
        if (req != null) begin
          drive_transfer(req);
          seq_item_port.item_done();
        end else begin
          // No item available: wait briefly or until a role-update event is triggered.
          bit timed_out;
          i2c_event_pool::wait_for_event_timeout(i2c_event_pool::ROLE_UPDATE, idle_poll_time, timed_out);
        end
      end else begin
        // --- SLAVE MODE ---
        // Listen to the bus (passive timing: SCL is observed, never driven).
        wait_for_request();
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // MASTER MODE TASKS
  // -----------------------------------------------------------------------
  task drive_transfer(i2c_transaction tr);
    // Enhanced Logging: Print full transaction details
    `uvm_info("DRV", $sformatf("Master Driving: %s", tr.convert2string()), UVM_LOW)
    
    // A preceding transfer may already have emitted the repeated START.
    // Its address follows directly; emitting another START loses that phase.
    if (master_restart_pending &&
        master_restart_epoch == i2c_event_pool::reset_epoch)
      master_restart_pending = 0;
    else
      send_start();
    
    // 2. Address + R/W
    send_byte({tr.addr[6:0], tr.direction}); 
    tr.accepted_data_bytes = 0;
    tr.nack_received = 0;
    wait_ack(tr.status, 1'b1);

    if (tr.status == I2C_STATUS_ADDR_NACK) begin
       `uvm_info("DRV", "Address NACK received, stopping", UVM_LOW)
       send_stop();
       return;
    end

    // 3. Data Transfer
    if (tr.direction == I2C_WRITE) begin
       foreach(tr.data[i]) begin
         send_byte(tr.data[i]);
         wait_ack(tr.status, 1'b0);
         if (tr.status == I2C_STATUS_DATA_NACK) begin
           tr.nack_received = 1;
           break;
         end
         tr.accepted_data_bytes++;
       end
    end else begin
       foreach(tr.data[i]) begin
         bit is_last = (i == tr.data.size() - 1);
         read_byte(tr.data[i]);
         if (is_last) send_nack();
         else         send_ack();
       end
    end

    // 4. Stop or Repeated Start
    if (tr.repeated_start)
      send_repeated_start();
    else
      send_stop();
  endtask

  // -----------------------------------------------------------------------
  // SLAVE MODE TASKS
  // -----------------------------------------------------------------------
  task wait_for_request();
    i2c_transaction tr;
    bit serviced;
    wait_for_request_result(tr, serviced);
  endtask

  // A cancelled listen is not a received transaction.  The result contains
  // only complete byte/ACK phases and is returned at STOP or repeated START.
  task wait_for_request_result(output i2c_transaction tr, output bit serviced);
    i2c_transaction captured_tr;
    logic [7:0] addr_byte;
    logic [7:0] data_byte;
    logic ack_bit;
    bit acked;
    bit address_complete;
    bit address_matched;
    bit boundary_seen;
    bit restart_seen;
    bit cancelled;
    int unsigned listen_epoch;

    tr = null;
    serviced = 0;
    address_complete = 0;
    address_matched = 0;
    boundary_seen = 0;
    restart_seen = 0;
    cancelled = 0;
    listen_epoch = i2c_event_pool::reset_epoch;
    if (slave_restart_epoch != listen_epoch)
      slave_restart_pending = 0;
    vif.scl_drive <= 1'b1;
    vif.sda_drive <= 1'b1;
    if (cfg.is_master) begin
      slave_restart_pending = 0;
      return;
    end

    fork
      begin : receive_request
        if (!slave_restart_pending) begin
          forever begin
            @(negedge vif.sda);
            if (vif.scl === 1'b1) break;
          end
        end
        slave_restart_pending = 0;
        captured_tr = i2c_transaction::type_id::create("slave_received_tr");
        captured_tr.data = new[0];
        captured_tr.addr_mode = I2C_ADDR_7BIT;

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
          begin : receive_bytes
            slave_read_byte(addr_byte);
            captured_tr.addr = addr_byte[7:1];
            captured_tr.direction = i2c_direction_e'(addr_byte[0]);
            address_matched = !$isunknown(addr_byte) &&
                              addr_byte[7:1] == cfg.slave_addr;
            if (address_matched)
              slave_send_ack_result(acked);
            else begin
              slave_sample_ack(ack_bit);
              acked = 0;
            end
            address_complete = 1;
            captured_tr.status = acked ? I2C_STATUS_OK : I2C_STATUS_ADDR_NACK;

            if (address_matched && acked) begin
              forever begin
                if (captured_tr.direction == I2C_WRITE) begin
                  slave_read_byte(data_byte);
                  if ($isunknown(data_byte)) begin
                    // Do not acknowledge an indeterminate byte as accepted.
                    slave_sample_ack(ack_bit);
                    captured_tr.status = I2C_STATUS_ERROR;
                    break;
                  end
                  slave_send_ack_result(acked);
                  ack_bit = !acked;
                end else begin
                  // The base behavioral responder retains its 0xFF value.
                  data_byte = 8'hFF;
                  slave_send_byte(data_byte);
                  slave_sample_ack(ack_bit);
                end

                captured_tr.data = new[captured_tr.data.size() + 1](captured_tr.data);
                captured_tr.data[captured_tr.data.size()-1] = data_byte;
                captured_tr.nack_received = (ack_bit !== 1'b0);
                if (captured_tr.direction == I2C_WRITE && ack_bit === 1'b0)
                  captured_tr.accepted_data_bytes++;
                if (ack_bit !== 1'b0) begin
                  if (captured_tr.direction == I2C_WRITE)
                    captured_tr.status = I2C_STATUS_DATA_NACK;
                  break;
                end
              end
            end
            // Byte acquisition ending (including NACK) is not a bus boundary.
            wait(boundary_seen);
          end
        join_any
        disable fork;
      end
      begin : cancel_listen
        wait(cfg.is_master || i2c_event_pool::reset_epoch != listen_epoch);
        cancelled = 1;
      end
    join_any
    disable fork;

    vif.scl_drive <= 1'b1;
    vif.sda_drive <= 1'b1;
    if (cancelled || cfg.is_master ||
        i2c_event_pool::reset_epoch != listen_epoch) begin
      slave_restart_pending = 0;
      return;
    end

    slave_restart_pending = restart_seen;
    slave_restart_epoch = listen_epoch;
    if (address_complete && address_matched && boundary_seen) begin
      captured_tr.repeated_start = restart_seen;
      if (captured_tr.direction == I2C_WRITE && captured_tr.data.size() > 0)
        captured_tr.decode_credit_header();
      tr = captured_tr;
      serviced = 1;
      `uvm_info("DRV_SLV", $sformatf("Slave serviced: %s", tr.convert2string()), UVM_LOW)
    end
  endtask


  // -----------------------------------------------------------------------
  // BIT BANGING HELPERS (MASTER - Active SCL Drive)
  // -----------------------------------------------------------------------
  
  task wait_half_period(int is_high_period);
     if (is_high_period)
       #(cfg.t_high_ns * 1ns);
     else
       #(cfg.t_low_ns * 1ns);
  endtask

  task send_start();
    master_restart_pending = 0;
    vif.sda_drive <= 1'b1;
    vif.scl_drive <= 1'b1;
    wait_half_period(1); 
    
    vif.sda_drive <= 1'b0; 
    wait_half_period(1);
    
    vif.scl_drive <= 1'b0; 
    wait_half_period(0);
  endtask

  task send_stop();
    master_restart_pending = 0;
    vif.scl_drive <= 1'b0;
    vif.sda_drive <= 1'b0;
    wait_half_period(0);
    
    vif.scl_drive <= 1'b1; 
    wait_half_period(1);
    
    vif.sda_drive <= 1'b1; 
    wait_half_period(1);
    #(cfg.t_buf_ns * 1ns);
  endtask
  
  task send_repeated_start();
    vif.scl_drive <= 1'b0;
    vif.sda_drive <= 1'b1;
    wait_half_period(0);
    
    vif.scl_drive <= 1'b1;
    wait_half_period(1);
    
    vif.sda_drive <= 1'b0; 
    wait_half_period(1);
    
    vif.scl_drive <= 1'b0;
    wait_half_period(0);
    master_restart_pending = 1;
    master_restart_epoch = i2c_event_pool::reset_epoch;
  endtask

  task send_byte(input bit [7:0] data);
    for(int i=7; i>=0; i--) begin
       vif.sda_drive <= data[i];
       wait_half_period(0); 
       
       vif.scl_drive <= 1'b1;
       wait_half_period(1);
       
       vif.scl_drive <= 1'b0;
    end
  endtask
  
  task read_byte(output bit [7:0] data);
    vif.sda_drive <= 1'b1; 
    
    for(int i=7; i>=0; i--) begin
       wait_half_period(0);
       
       vif.scl_drive <= 1'b1;
       wait_half_period(1);
       
       data[i] = vif.sda; 
       
       vif.scl_drive <= 1'b0;
    end
  endtask
  
  task wait_ack(output i2c_status_e status, input bit address_phase);
    vif.sda_drive <= 1'b1;
    wait_half_period(0);
    
    vif.scl_drive <= 1'b1;
    wait_half_period(1);
    
    if (vif.sda === 1'b0) begin
       status = I2C_STATUS_OK;
       `uvm_info("DRV", "ACK Received", UVM_HIGH)
    end else begin
       status = address_phase ? I2C_STATUS_ADDR_NACK : I2C_STATUS_DATA_NACK;
       `uvm_info("DRV", "NACK Received", UVM_HIGH)
    end
    
    vif.scl_drive <= 1'b0;
  endtask

  task send_ack();
    vif.sda_drive <= 1'b0;
    wait_half_period(0);
    vif.scl_drive <= 1'b1;
    wait_half_period(1);
    vif.scl_drive <= 1'b0;
  endtask

  task send_nack();
    vif.sda_drive <= 1'b1;
    wait_half_period(0);
    vif.scl_drive <= 1'b1;
    wait_half_period(1);
    vif.scl_drive <= 1'b0;
  endtask

  // -----------------------------------------------------------------------
  // BIT BANGING HELPERS (SLAVE - Passive SCL Observe)
  // -----------------------------------------------------------------------

  task slave_read_byte(output logic [7:0] data);
    vif.sda_drive <= 1'b1; // Release SDA to read
    vif.scl_drive <= 1'b1; // Ensure we don't drive SCL
    
    for(int i=7; i>=0; i--) begin
       // Wait for SCL Rising Edge (Sample point)
       @(posedge vif.scl);
       data[i] = vif.sda;
       // Wait for SCL Falling Edge (Next bit setup)
       @(negedge vif.scl);
    end
  endtask

  task slave_send_byte(input bit [7:0] data);
    vif.scl_drive <= 1'b1; // Ensure we don't drive SCL
    
    for(int i=7; i>=0; i--) begin
       // Data setup (after SCL fell)
       vif.sda_drive <= data[i];
       
       // Wait for SCL Rising Edge (Master samples)
       @(posedge vif.scl);
       // Wait for SCL Falling Edge
       @(negedge vif.scl);
    end
    // Release SDA after last bit
    vif.sda_drive <= 1'b1;
  endtask

  task slave_send_ack();
    bit acked;
    slave_send_ack_result(acked);
  endtask

  task slave_send_ack_result(output bit acked);
    vif.scl_drive <= 1'b1; 
    
    // Drive ACK (Low)
    vif.sda_drive <= 1'b0;
    
    // Wait for Master to clock the ACK
    @(posedge vif.scl);
    acked = (vif.sda === 1'b0);
    @(negedge vif.scl);
    
    // Release SDA
    vif.sda_drive <= 1'b1;
  endtask

  task slave_wait_ack_or_nack();
    logic ack_bit;
    slave_sample_ack(ack_bit);
  endtask

  task slave_sample_ack(output logic ack_bit);
    vif.scl_drive <= 1'b1;
    vif.sda_drive <= 1'b1; // Release SDA
    
    @(posedge vif.scl);
    ack_bit = vif.sda;
    @(negedge vif.scl);
  endtask

endclass

`endif // I2C_DRIVER_SV
