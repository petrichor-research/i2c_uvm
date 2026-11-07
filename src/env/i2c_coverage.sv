`ifndef I2C_COVERAGE_SV
`define I2C_COVERAGE_SV

class i2c_coverage extends uvm_subscriber #(i2c_transaction);
  `uvm_component_utils(i2c_coverage)

  i2c_config cfg;
  
  protected i2c_transaction req;

  // ---- Credit-mode sampled fields ----
  protected i2c_credit_frame_e  sampled_frame_type;
  protected int                 sampled_credit_counter;
  protected i2c_credit_state_e  sampled_credit_state;
  protected int                 sampled_credit_data_size;

  covergroup i2c_protocol_cg;
    option.per_instance = 1;

    cp_addr_mode: coverpoint req.addr_mode { 
      bins addr_7bit  = {I2C_ADDR_7BIT};
      bins addr_10bit = {I2C_ADDR_10BIT};
    }
    
    cp_addr_7bit: coverpoint req.addr {
       bins zero        = {0};
       bins gen_call    = {0};
       bins low_range   = {[1:15]};
       bins mid_range   = {[16:111]};
       bins high_range  = {[112:126]};
       bins max_val     = {127};
    }

    cp_direction: coverpoint req.direction {
       bins write = {I2C_WRITE};
       bins read  = {I2C_READ};
    }

    cp_status: coverpoint req.status {
       bins ok        = {I2C_STATUS_OK};
       bins addr_nack = {I2C_STATUS_ADDR_NACK};
       bins data_nack = {I2C_STATUS_DATA_NACK};
    }

    cp_data_size: coverpoint req.data.size() {
       bins single_byte = {1};
       bins small_burst = {[2:8]};
       bins large_burst = {[9:128]};
    }

    cp_repeated_start: coverpoint req.repeated_start {
       bins stop_end = {0};
       bins rep_start = {1};
    }

    cross_dir_status: cross cp_direction, cp_status;
    cross_dir_size:   cross cp_direction, cp_data_size;
    cross_rep_start:  cross cp_direction, cp_repeated_start;

  endgroup

  covergroup i2c_config_cg;
     option.per_instance = 1;
     
     cp_speed: coverpoint cfg.speed {
        bins standard = {I2C_STANDARD_MODE};
        bins fast     = {I2C_FAST_MODE};
        bins fast_plus = {I2C_FAST_MODE_PLUS};
     }
  endgroup

  // ---- Credit Protocol Coverage ----
  covergroup credit_protocol_cg;
    option.per_instance = 1;

    cp_frame_type: coverpoint sampled_frame_type {
      bins data_frame   = {I2C_CREDIT_FRAME_DATA};
      bins init_frame   = {I2C_CREDIT_FRAME_INIT};
      bins return_frame = {I2C_CREDIT_FRAME_RETURN};
      bins status_frame = {I2C_CREDIT_FRAME_STATUS};
    }

    cp_credit_state: coverpoint sampled_credit_state {
      bins reset     = {CREDIT_STATE_RESET};
      bins init      = {CREDIT_STATE_INIT};
      bins ready     = {CREDIT_STATE_READY};
      bins active    = {CREDIT_STATE_ACTIVE};
      bins exhausted = {CREDIT_STATE_EXHAUSTED};
      bins error     = {CREDIT_STATE_ERROR};
    }

    cp_credit_counter: coverpoint sampled_credit_counter {
      bins zero       = {0};
      bins low        = {[1:2]};
      bins mid        = {[3:6]};
      bins high       = {[7:15]};
      bins full       = {[16:256]};
      illegal_bins negative = {[-256:-1]};
    }

    cp_data_size: coverpoint sampled_credit_data_size {
      bins single = {1};
      bins small_payload  = {[2:4]};
      bins medium_payload = {[5:16]};
      bins large_payload  = {[17:128]};
    }

    cross_frame_state: cross cp_frame_type, cp_credit_state;
    cross_frame_counter: cross cp_frame_type, cp_credit_counter;
  endgroup

  covergroup credit_transition_cg;
    option.per_instance = 1;

    cp_state_transition: coverpoint sampled_credit_state {
      bins init_to_ready     = (CREDIT_STATE_INIT     => CREDIT_STATE_READY);
      bins ready_to_active   = (CREDIT_STATE_READY    => CREDIT_STATE_ACTIVE);
      bins active_to_exhaust = (CREDIT_STATE_ACTIVE   => CREDIT_STATE_EXHAUSTED);
      bins exhaust_to_active = (CREDIT_STATE_EXHAUSTED => CREDIT_STATE_ACTIVE);
      bins active_to_ready   = (CREDIT_STATE_ACTIVE   => CREDIT_STATE_READY);
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    i2c_protocol_cg    = new();
    i2c_config_cg      = new();
    credit_protocol_cg   = new();
    credit_transition_cg = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(i2c_config)::get(this, "", "cfg", cfg)) begin
       `uvm_info("COV", "Config not found, creating default", UVM_LOW)
       cfg = i2c_config::type_id::create("cfg");
    end
  endfunction

  function void write(i2c_transaction t);
    this.req = t; 
    
    i2c_protocol_cg.sample();
    i2c_config_cg.sample();

    if (cfg.credit_mode_enable) begin
      sampled_frame_type       = t.frame_type;
      sampled_credit_counter   = t.credit_counter_snapshot;
      sampled_credit_state     = t.credit_state_snapshot;
      sampled_credit_data_size = t.data.size();
      credit_protocol_cg.sample();
      credit_transition_cg.sample();
    end
  endfunction

endclass

`endif // I2C_COVERAGE_SV
