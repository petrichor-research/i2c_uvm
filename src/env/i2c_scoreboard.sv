`ifndef I2C_SCOREBOARD_SV
`define I2C_SCOREBOARD_SV

class i2c_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(i2c_scoreboard)
  
  `uvm_register_cb(i2c_scoreboard, i2c_scoreboard_callback)
  
  uvm_tlm_analysis_fifo #(i2c_transaction) analysis_fifo;
  uvm_analysis_imp #(i2c_transaction, i2c_scoreboard) item_imp;
  
  i2c_transaction expected_queue[$];
  i2c_config cfg;
  
  int unsigned total_received  = 0;
  int unsigned total_compared  = 0;
  int unsigned total_matched   = 0;
  int unsigned total_mismatched = 0;
  
  bit enable_comparison = 1;
  
  // ---- Credit-mode accounting ----
  int unsigned credit_data_transactions;
  int unsigned credit_init_frames;
  int unsigned credit_return_frames;
  // Legacy field name: this is a raw frame-count difference, not a credit
  // balance (INIT/RETURN payload counts and ACKed bytes have different units).
  int credit_balance_delta;
  
  uvm_event transaction_received_event;
  uvm_event comparison_done_event;
  uvm_event mismatch_event;
  
  function new(string name, uvm_component parent);
    super.new(name, parent);
    item_imp = new("item_imp", this);
    credit_data_transactions = 0;
    credit_init_frames = 0;
    credit_return_frames = 0;
  endfunction
  
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    
    analysis_fifo = new("analysis_fifo", this);
    
    transaction_received_event = new("transaction_received_event");
    comparison_done_event = new("comparison_done_event");
    mismatch_event = new("mismatch_event");

    if (!uvm_config_db#(i2c_config)::get(this, "", "cfg", cfg)) begin
      cfg = i2c_config::type_id::create("cfg");
    end
    
    `uvm_info("SCB", "Scoreboard built with TLM FIFO and event synchronization", UVM_MEDIUM)
  endfunction
  
  function void write(i2c_transaction tr);
    i2c_transaction tr_copy;
    
    total_received++;
    
    tr_copy = i2c_transaction::type_id::create("tr_copy");
    tr_copy.copy(tr);
    
    analysis_fifo.write(tr_copy);
    transaction_received_event.trigger(tr_copy);

    // Credit-mode frame accounting
    if (cfg.credit_mode_enable) begin
      case (tr.frame_type)
        I2C_CREDIT_FRAME_DATA:   credit_data_transactions++;
        I2C_CREDIT_FRAME_INIT:   credit_init_frames++;
        I2C_CREDIT_FRAME_RETURN: credit_return_frames++;
        default: ;
      endcase
    end
    
    `uvm_info("SCB", $sformatf("Received transaction #%0d: %s", 
              total_received, tr.convert2string()), UVM_HIGH)
  endfunction
  
  task run_phase(uvm_phase phase);
    i2c_transaction actual_tr;
    
    forever begin
      analysis_fifo.get(actual_tr);
      
      if (enable_comparison && expected_queue.size() > 0) begin
        compare_with_expected(actual_tr);
      end else begin
        `uvm_info("SCB", $sformatf("Actual: %s", actual_tr.convert2string()), UVM_MEDIUM)
      end
    end
  endtask
  
  function void compare_with_expected(i2c_transaction actual);
    i2c_transaction expected;
    bit matched = 1;
    
    expected = expected_queue.pop_front();
    total_compared++;
    
    if (expected.addr !== actual.addr) begin
      matched = 0;
      `uvm_error("SCB", $sformatf("Address mismatch: exp=0x%02h, act=0x%02h",
                                  expected.addr, actual.addr))
    end
    
    if (expected.direction !== actual.direction) begin
      matched = 0;
      `uvm_error("SCB", $sformatf("Direction mismatch: exp=%s, act=%s",
                                  expected.direction.name(), actual.direction.name()))
    end
    
    if (expected.data.size() != actual.data.size()) begin
      matched = 0;
      `uvm_error("SCB", $sformatf("Data size mismatch: exp=%0d, act=%0d",
                                  expected.data.size(), actual.data.size()))
    end else begin
      foreach (expected.data[i]) begin
        if (expected.data[i] !== actual.data[i]) begin
          matched = 0;
          `uvm_error("SCB", $sformatf("Data[%0d] mismatch: exp=0x%02h, act=0x%02h",
                                      i, expected.data[i], actual.data[i]))
        end
      end
    end
    
    if (matched) begin
      total_matched++;
      `uvm_info("SCB", $sformatf("Transaction #%0d MATCHED", total_compared), UVM_MEDIUM)
    end else begin
      total_mismatched++;
      mismatch_event.trigger(actual);
    end
    
    comparison_done_event.trigger();
  endfunction
  
  function void add_expected(i2c_transaction tr);
    i2c_transaction tr_copy;
    tr_copy = i2c_transaction::type_id::create("expected_tr");
    tr_copy.copy(tr);
    expected_queue.push_back(tr_copy);
    `uvm_info("SCB", $sformatf("Added expected: %s (queue size=%0d)", 
              tr.convert2string(), expected_queue.size()), UVM_HIGH)
  endfunction
  
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    
    if (expected_queue.size() > 0)
      `uvm_error("SCB", $sformatf("%0d expected transactions unmatched", expected_queue.size()))

    if (cfg.credit_mode_enable) begin
      credit_balance_delta = credit_init_frames + credit_return_frames - credit_data_transactions;
      `uvm_info("SCB", $sformatf(
        "Observed wire frames: init=%0d data=%0d returns=%0d raw_frame_delta=%0d (not a credit balance)",
        credit_init_frames, credit_data_transactions, credit_return_frames, credit_balance_delta), UVM_LOW)
    end
  endfunction
  
  function void report_phase(uvm_phase phase);
    real match_rate;
    super.report_phase(phase);
    
    match_rate = (total_compared > 0) ? (100.0 * total_matched / total_compared) : 0.0;
    
    `uvm_info("SCB", "╔════════════════════════════════════╗", UVM_NONE)
    `uvm_info("SCB", "║    SCOREBOARD STATISTICS           ║", UVM_NONE)
    `uvm_info("SCB", "╠════════════════════════════════════╣", UVM_NONE)
    `uvm_info("SCB", $sformatf("║ Received:    %8d             ║", total_received), UVM_NONE)
    `uvm_info("SCB", $sformatf("║ Compared:    %8d             ║", total_compared), UVM_NONE)
    `uvm_info("SCB", $sformatf("║ Matched:     %8d             ║", total_matched), UVM_NONE)
    `uvm_info("SCB", $sformatf("║ Mismatched:  %8d             ║", total_mismatched), UVM_NONE)
    if (total_compared > 0)
      `uvm_info("SCB", $sformatf("║ Match Rate:  %7.1f%%            ║", match_rate), UVM_NONE)
    else
      `uvm_info("SCB", "║ Match Rate: N/A (no comparisons)    ║", UVM_NONE)
    if (cfg.credit_mode_enable) begin
      `uvm_info("SCB", "╠════════════════════════════════════╣", UVM_NONE)
      `uvm_info("SCB", $sformatf("║ Credit Data: %8d             ║", credit_data_transactions), UVM_NONE)
      `uvm_info("SCB", $sformatf("║ Credit Init: %8d             ║", credit_init_frames), UVM_NONE)
      `uvm_info("SCB", $sformatf("║ Credit Ret:  %8d             ║", credit_return_frames), UVM_NONE)
      `uvm_info("SCB", $sformatf("║ Frame Delta: %8d (not budget)║", credit_balance_delta), UVM_NONE)
    end
    `uvm_info("SCB", "╚════════════════════════════════════╝", UVM_NONE)
  endfunction
  
  task wait_for_comparisons(int count = 1);
    repeat(count) begin
      comparison_done_event.wait_trigger();
      comparison_done_event.reset();
    end
  endtask

endclass

`endif // I2C_SCOREBOARD_SV
