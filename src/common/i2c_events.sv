`ifndef I2C_EVENTS_SV
`define I2C_EVENTS_SV

//==============================================================================
// I2C Event Definitions
// 
// Uses uvm_event_pool for global event synchronization across components.
// Events enable loose coupling between testbench components.
//==============================================================================

class i2c_event_pool extends uvm_object;
  `uvm_object_utils(i2c_event_pool)
  
  // Global Event Pool (singleton pattern)
  static uvm_event_pool global_pool;
  // Generation counter also cancels edge waits that have no reset pin in i2c_if.
  static int unsigned reset_epoch = 0;
  
  // Event Names (constants for consistency)
  static string RESET_DONE       = "reset_done";
  static string START_DETECTED   = "start_detected";
  static string STOP_DETECTED    = "stop_detected";
  static string ADDR_PHASE_DONE  = "addr_phase_done";
  static string DATA_PHASE_DONE  = "data_phase_done";
  static string TRANS_COMPLETE   = "trans_complete";
  static string NACK_RECEIVED    = "nack_received";
  static string ARB_LOST         = "arb_lost";
  static string BUS_IDLE         = "bus_idle";
  static string ROLE_UPDATE      = "role_update";   // Config/role change request (wake-up hint)
  static string ROLE_COMMITTED   = "role_committed"; // Role change committed (optional)
  static string ERROR_DETECTED   = "error_detected";

  // Credit INIT/RETURN delivery is persistent and broadcast by queueing one
  // entry per permanent consumer.  The accompanying uvm_event is only a
  // wake-up hint; the queue, not the pulse, is the source of truth.
  static string CREDIT_INIT_CBT_AVAILABLE = "credit_init_cbt_available";
  static string CREDIT_INIT_MON_AVAILABLE = "credit_init_monitor_available";
  static string CREDIT_RET_CBT_AVAILABLE  = "credit_return_cbt_available";
  static string CREDIT_RET_MON_AVAILABLE  = "credit_return_monitor_available";

  static i2c_credit_event_payload credit_init_cbt_q[$];
  static i2c_credit_event_payload credit_init_mon_q[$];
  static i2c_credit_event_payload credit_return_cbt_q[$];
  static i2c_credit_event_payload credit_return_mon_q[$];
  // INIT is a single grant per reset epoch, even after both queues are drained.
  static bit credit_init_published = 0;
  
  function new(string name = "i2c_event_pool");
    super.new(name);
  endfunction
  
  //----------------------------------------------------------------------------
  // Get Global Pool (Singleton)
  //----------------------------------------------------------------------------
  static function uvm_event_pool get_global_pool();
    if (global_pool == null) begin
      global_pool = new("i2c_global_event_pool");
      `uvm_info("I2C_EVENT_POOL", "Created global event pool", UVM_LOW)
    end
    return global_pool;
  endfunction
  
  //----------------------------------------------------------------------------
  // Get Event by Name (creates if doesn't exist)
  //----------------------------------------------------------------------------
  static function uvm_event get_event(string name);
    uvm_event_pool pool = get_global_pool();
    return pool.get(name);
  endfunction
  
  //----------------------------------------------------------------------------
  // Trigger Event with Optional Data
  //----------------------------------------------------------------------------
  static function void trigger_event(string name, uvm_object data = null);
    uvm_event ev = get_event(name);
    ev.trigger(data);
    `uvm_info("I2C_EVENT", $sformatf("Event '%s' triggered", name), UVM_HIGH)
  endfunction
  
  //----------------------------------------------------------------------------
  // Wait for Event (blocking task)
  //----------------------------------------------------------------------------
  static task wait_for_event(string name, output uvm_object data);
    uvm_event ev = get_event(name);
    ev.wait_trigger_data(data);
    `uvm_info("I2C_EVENT", $sformatf("Event '%s' received", name), UVM_HIGH)
  endtask
  
  //----------------------------------------------------------------------------
  // Wait for Event with Timeout
  //----------------------------------------------------------------------------
  static task wait_for_event_timeout(string name, time timeout, output bit timed_out);
    uvm_event ev = get_event(name);
    timed_out = 0;
    
    fork
      begin
        ev.wait_trigger();
        timed_out = 0;
      end
      begin
        #timeout;
        timed_out = 1;
      end
    join_any
    disable fork;
    
    if (timed_out)
      `uvm_info("I2C_EVENT", $sformatf("Event '%s' timed out after %0t", name, timeout), UVM_HIGH)
  endtask

  //----------------------------------------------------------------------------
  // Persistent Credit-Event Channels
  //----------------------------------------------------------------------------
  static function bit valid_credit_payload(
    i2c_credit_event_payload payload, i2c_credit_frame_e expected_type);
    if (payload == null) begin
      `uvm_error("I2C_EVENT", $sformatf(
        "Rejected %s payload: null handle", expected_type.name()))
      return 0;
    end

    if (payload.frame_type != expected_type || payload.credit_count == 0 ||
        payload.credit_count > I2C_CREDIT_MAX_DEPTH) begin
      `uvm_error("I2C_EVENT", $sformatf(
        "Rejected %s payload: type=%s count=%0d",
        expected_type.name(), payload.frame_type.name(), payload.credit_count))
      return 0;
    end
    return 1;
  endfunction

  static function bit publish_credit_init(i2c_credit_event_payload payload);
    if (!valid_credit_payload(payload, I2C_CREDIT_FRAME_INIT))
      return 0;

    if (credit_init_published) begin
      `uvm_error("I2C_EVENT", "Rejected duplicate credit INIT in the current reset epoch")
      return 0;
    end

    credit_init_cbt_q.push_back(snapshot_credit_payload(payload));
    credit_init_mon_q.push_back(snapshot_credit_payload(payload));
    credit_init_published = 1;
    trigger_event(CREDIT_INIT_CBT_AVAILABLE);
    trigger_event(CREDIT_INIT_MON_AVAILABLE);
    return 1;
  endfunction

  static function bit publish_credit_return(i2c_credit_event_payload payload);
    if (!valid_credit_payload(payload, I2C_CREDIT_FRAME_RETURN))
      return 0;

    credit_return_cbt_q.push_back(snapshot_credit_payload(payload));
    credit_return_mon_q.push_back(snapshot_credit_payload(payload));
    trigger_event(CREDIT_RET_CBT_AVAILABLE);
    trigger_event(CREDIT_RET_MON_AVAILABLE);
    return 1;
  endfunction

  // Snapshot the value separately for each permanent consumer.  Neither the
  // publisher nor a consumer can mutate the other consumer's retained entry.
  static function i2c_credit_event_payload snapshot_credit_payload(
    i2c_credit_event_payload payload);
    i2c_credit_event_payload snapshot = new("credit_event_snapshot");
    snapshot.frame_type = payload.frame_type;
    snapshot.credit_count = payload.credit_count;
    snapshot.physical_release_observed = payload.physical_release_observed;
    return snapshot;
  endfunction

  static function bit try_get_credit_init(
    i2c_credit_consumer_e consumer,
    output i2c_credit_event_payload payload);
    payload = null;
    case (consumer)
      I2C_CREDIT_CONSUMER_CBT: begin
        if (credit_init_cbt_q.size() == 0) return 0;
        payload = credit_init_cbt_q.pop_front();
      end
      I2C_CREDIT_CONSUMER_MONITOR: begin
        if (credit_init_mon_q.size() == 0) return 0;
        payload = credit_init_mon_q.pop_front();
      end
      default: return 0;
    endcase
    return 1;
  endfunction

  static function bit try_get_credit_return(
    i2c_credit_consumer_e consumer,
    output i2c_credit_event_payload payload);
    payload = null;
    case (consumer)
      I2C_CREDIT_CONSUMER_CBT: begin
        if (credit_return_cbt_q.size() == 0) return 0;
        payload = credit_return_cbt_q.pop_front();
      end
      I2C_CREDIT_CONSUMER_MONITOR: begin
        if (credit_return_mon_q.size() == 0) return 0;
        payload = credit_return_mon_q.pop_front();
      end
      default: return 0;
    endcase
    return 1;
  endfunction

  static function uvm_event get_credit_init_available_event(
    i2c_credit_consumer_e consumer);
    if (consumer == I2C_CREDIT_CONSUMER_CBT)
      return get_event(CREDIT_INIT_CBT_AVAILABLE);
    return get_event(CREDIT_INIT_MON_AVAILABLE);
  endfunction

  static function uvm_event get_credit_return_available_event(
    i2c_credit_consumer_e consumer);
    if (consumer == I2C_CREDIT_CONSUMER_CBT)
      return get_event(CREDIT_RET_CBT_AVAILABLE);
    return get_event(CREDIT_RET_MON_AVAILABLE);
  endfunction

  static task wait_for_credit_init(
    i2c_credit_consumer_e consumer,
    output i2c_credit_event_payload payload);
    uvm_event available_ev;
    available_ev = get_credit_init_available_event(consumer);
    forever begin
      if (try_get_credit_init(consumer, payload)) return;
      // The queue check and blocking wait are contiguous in one process, so a
      // producer cannot interleave between them.  wait_trigger() also avoids a
      // same-time-slot busy loop after a persistent trigger has been consumed.
      available_ev.wait_trigger();
    end
  endtask

  static task wait_for_credit_return(
    i2c_credit_consumer_e consumer,
    output i2c_credit_event_payload payload);
    uvm_event available_ev;
    available_ev = get_credit_return_available_event(consumer);
    forever begin
      if (try_get_credit_return(consumer, payload)) return;
      available_ev.wait_trigger();
    end
  endtask

  static task wait_for_credit_init_timeout(
    i2c_credit_consumer_e consumer, time timeout,
    output bit timed_out,
    output i2c_credit_event_payload payload);
    timed_out = 0;
    payload = null;
    fork
      wait_for_credit_init(consumer, payload);
      begin
        #timeout;
        timed_out = 1;
      end
    join_any
    disable fork;
  endtask

  static task wait_for_credit_return_timeout(
    i2c_credit_consumer_e consumer, time timeout,
    output bit timed_out,
    output i2c_credit_event_payload payload);
    timed_out = 0;
    payload = null;
    fork
      wait_for_credit_return(consumer, payload);
      begin
        #timeout;
        timed_out = 1;
      end
    join_any
    disable fork;
  endtask
  
  //----------------------------------------------------------------------------
  // Reset Event (clear trigger state)
  //----------------------------------------------------------------------------
  static function void reset_event(string name);
    uvm_event ev = get_event(name);
    ev.reset();
  endfunction
  
  //----------------------------------------------------------------------------
  // Reset All Events
  //----------------------------------------------------------------------------
  static function void reset_all_events();
    uvm_event_pool pool = get_global_pool();
    string event_names[$];
    reset_epoch++;
    
    // Reset known events
    reset_event(RESET_DONE);
    reset_event(START_DETECTED);
    reset_event(STOP_DETECTED);
    reset_event(ADDR_PHASE_DONE);
    reset_event(DATA_PHASE_DONE);
    reset_event(TRANS_COMPLETE);
    reset_event(NACK_RECEIVED);
    reset_event(ARB_LOST);
    reset_event(BUS_IDLE);
    reset_event(ROLE_UPDATE);
    reset_event(ROLE_COMMITTED);
    reset_event(ERROR_DETECTED);
    reset_event(CREDIT_INIT_CBT_AVAILABLE);
    reset_event(CREDIT_INIT_MON_AVAILABLE);
    reset_event(CREDIT_RET_CBT_AVAILABLE);
    reset_event(CREDIT_RET_MON_AVAILABLE);

    credit_init_cbt_q.delete();
    credit_init_mon_q.delete();
    credit_return_cbt_q.delete();
    credit_return_mon_q.delete();
    credit_init_published = 0;
  endfunction

endclass

`endif // I2C_EVENTS_SV
