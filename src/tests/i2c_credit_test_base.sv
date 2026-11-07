`ifndef I2C_CREDIT_TEST_BASE_SV
`define I2C_CREDIT_TEST_BASE_SV

// A single sequencer request whose mutated response remains visible to its test.
class i2c_credit_probe_sequence extends i2c_credit_base_sequence;
  `uvm_object_utils(i2c_credit_probe_sequence)
  i2c_transaction result;

  function new(string name = "i2c_credit_probe_sequence");
    super.new(name);
  endfunction

  task body();
    result = i2c_transaction::type_id::create("probe_request");
    result.direction = I2C_WRITE;
    result.addr_mode = I2C_ADDR_7BIT;
    result.addr = target_addr;
    result.frame_type = I2C_CREDIT_FRAME_DATA;
    result.data = new[1];
    result.data[0] = 8'h35;
    if (!result.encode_credit_header())
      `uvm_fatal("CREDIT_TEST", "Probe DATA encoding failed")
    start_item(result);
    finish_item(result);
  endtask
endclass

class i2c_credit_test_base extends i2c_test_base;
  `uvm_component_utils(i2c_credit_test_base)

  int unsigned expected_accepted_bytes;
  int unsigned expected_bus_transactions;
  int unsigned expected_tbi1_diagnostics;
  int unsigned expected_stall_episodes;
  bit scenario_completed;

  function new(string name = "i2c_credit_test_base", uvm_component parent = null);
    super.new(name, parent);
    expected_accepted_bytes = 0;
    expected_bus_transactions = 0;
    expected_tbi1_diagnostics = 0;
    expected_stall_episodes = 0;
    scenario_completed = 0;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Enable credit mode on the shared config
    cfg.credit_mode_enable = 1;
    configure_credit_params();

    // tb_top instantiates i2c_credit_slave with FIFO_DEPTH=8.  Runs that use
    // this physical endpoint must not advertise a different capacity.
    if (cfg.cbr_depth != I2C_CREDIT_DEFAULT_DEPTH) begin
      `uvm_fatal("CREDIT_CFG", $sformatf(
        "Matched-capacity requirement failed: advertised D=%0d, physical P=%0d",
        cfg.cbr_depth, I2C_CREDIT_DEFAULT_DEPTH))
    end

    // Re-propagate the updated config
    uvm_config_db#(i2c_config)::set(this, "env*", "cfg", cfg);
  endfunction

  virtual function void configure_credit_params();
    cfg.cbr_depth = I2C_CREDIT_DEFAULT_DEPTH;
    cfg.cbr_pipe_delay = I2C_CREDIT_DEFAULT_PIPE_DLY;
    cfg.cbt_pipe_delay = 0;
    cfg.cbr_return_burst = 1;
  endfunction

  task start_credit_sequence_bounded(uvm_sequence_base seq, output bit completed);
    completed = 0;
    fork : sequence_deadline
      begin
        seq.start(env.agent.cbt_sequencer);
        completed = 1;
      end
      begin #5ms; end
    join_any
    disable sequence_deadline;
    if (!completed) begin
      seq.kill();
      `uvm_error("CREDIT_TEST", "Unexpected test-sequence timeout; sequence cancelled")
    end
  endtask

  task run_credit_data_count(int unsigned frames, string sequence_name,
                             output bit completed);
    i2c_credit_data_sequence seq;
    int unsigned sent_before;
    int unsigned observed_before;
    sent_before = env.agent.cbt_driver.total_data_sent;
    observed_before = env.agent.credit_monitor.total_credits_consumed;
    seq = i2c_credit_data_sequence::type_id::create(sequence_name);
    seq.cfg = cfg;
    seq.target_addr = cfg.slave_addr;
    seq.num_frames = frames;
    start_credit_sequence_bounded(seq, completed);
    if (!completed) return;
    #1ns;
    if (env.agent.cbt_driver.total_data_sent != sent_before + frames ||
        env.agent.credit_monitor.total_credits_consumed != observed_before + frames) begin
      completed = 0;
      `uvm_error("CREDIT_TEST", "DATA phase did not produce the expected ACK-qualified byte count")
    end
  endtask

  function void check_phase(uvm_phase phase);
    int expected_balance;
    super.check_phase(phase);
    if (!scenario_completed)
      `uvm_error("CREDIT_TEST", "Credit scenario did not complete its explicit oracle")
    if (env.agent.cbt_driver == null || env.agent.cbr_driver == null ||
        env.agent.credit_monitor == null) begin
      `uvm_error("CREDIT_TEST", "Active credit components are missing")
      return;
    end
    expected_balance = int'(cfg.cbr_depth) - int'(expected_accepted_bytes);
    if (expected_accepted_bytes > cfg.cbr_depth ||
        !env.agent.cbt_driver.init_complete || !env.agent.credit_monitor.init_complete ||
        env.agent.cbt_driver.total_data_sent != expected_accepted_bytes ||
        env.agent.credit_monitor.total_credits_consumed != expected_accepted_bytes ||
        env.agent.cbt_driver.credit_counter != expected_balance ||
        env.agent.credit_monitor.shadow_credit_counter != expected_balance ||
        env.scoreboard.credit_data_transactions != expected_bus_transactions ||
        env.agent.cbt_driver.total_stall_cycles != expected_stall_episodes) begin
      `uvm_error("CREDIT_TEST", $sformatf(
        "No-RETURN accounting oracle failed: expected accepted=%0d bus_transactions=%0d balance=%0d stalls=%0d; observed accepted=%0d/%0d transactions=%0d balances=%0d/%0d stalls=%0d",
        expected_accepted_bytes, expected_bus_transactions, expected_balance, expected_stall_episodes,
        env.agent.cbt_driver.total_data_sent, env.agent.credit_monitor.total_credits_consumed,
        env.scoreboard.credit_data_transactions, env.agent.cbt_driver.credit_counter,
        env.agent.credit_monitor.shadow_credit_counter, env.agent.cbt_driver.total_stall_cycles))
    end
    if (env.agent.credit_monitor.total_credits_init != cfg.cbr_depth ||
        env.agent.cbt_driver.total_credits_received != cfg.cbr_depth ||
        env.agent.credit_monitor.total_credits_returned != 0 ||
        env.agent.cbr_driver.total_data_received != 0 ||
        env.agent.cbr_driver.total_credits_returned != 0 ||
        env.agent.cbr_driver.cr_return_pipe.size() != 0)
      `uvm_error("CREDIT_TEST", "No-RETURN topology unexpectedly changed INIT/receive/return accounting")
    if (env.agent.credit_monitor.tbi1_violations != expected_tbi1_diagnostics ||
        env.agent.credit_monitor.tbi2_violations != 0 ||
        env.agent.credit_monitor.tbi3_violations != 0 ||
        env.agent.credit_monitor.tbi5_violations != 0 ||
        env.agent.credit_monitor.tbi6_violations != 0)
      `uvm_error("CREDIT_TEST", "Unexpected credit-monitor diagnostic count")
  endfunction

endclass

`endif // I2C_CREDIT_TEST_BASE_SV
