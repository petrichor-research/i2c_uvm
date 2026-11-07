`timescale 1ns/1ps
`define uvm_object_utils(T)
`define uvm_object_utils_begin(T)
`define uvm_object_utils_end
`define uvm_component_utils(T)
`define uvm_field_enum(T,F,O)
`define uvm_field_int(F,O)
`define uvm_info(ID,MSG,LEVEL) ;
`define uvm_warning(ID,MSG) $display("EXPECTED_DIAGNOSTIC %s: %s", ID, MSG);
`define uvm_error(ID,MSG) begin test_diagnostics::errors++; $display("EXPECTED_DIAGNOSTIC %s: %s", ID, MSG); end

// Minimal plumbing only. Event wakeups, UVM scheduling, virtual interfaces,
// factories, and analysis connections are deliberately outside this harness.
class test_diagnostics;
  static int unsigned errors = 0;
endclass
class uvm_object;
  function new(string name = ""); endfunction
endclass
class uvm_phase extends uvm_object;
endclass
class uvm_component extends uvm_object;
  function new(string name = "", uvm_component parent = null); super.new(name); endfunction
endclass
class uvm_monitor extends uvm_component;
  function new(string name = "", uvm_component parent = null); super.new(name, parent); endfunction
  function void check_phase(uvm_phase phase); endfunction
endclass
class uvm_event extends uvm_object;
  function new(string name = ""); super.new(name); endfunction
  function void trigger(uvm_object data = null); endfunction
  function void reset(); endfunction
endclass
class uvm_event_pool extends uvm_object;
  function new(string name = ""); super.new(name); endfunction
  function uvm_event get(string name);
    uvm_event result = new(name);
    return result;
  endfunction
endclass
class uvm_analysis_port #(type T = int);
  function new(string name, uvm_component parent); endfunction
endclass

// SOURCE_TYPES

class i2c_config;
  int unsigned cbr_depth = 8;
  bit credit_mode_enable = 1;
endclass
class i2c_transaction extends uvm_object;
  i2c_direction_e direction = I2C_WRITE;
  i2c_credit_frame_e frame_type = I2C_CREDIT_FRAME_DATA;
  i2c_status_e status = I2C_STATUS_OK;
  bit [7:0] data[];
  int unsigned credit_count;
  int unsigned accepted_data_bytes;
  function new(string name = ""); super.new(name); endfunction
  // SOURCE_VALIDATOR
endclass

// SOURCE_EVENTS
// SOURCE_MONITOR

module tb_credit_events;
  integer checks = 0;
  task automatic require(input bit condition, input string context_name);
    checks++;
    if (!condition) $fatal(1, "%s", context_name);
  endtask

  function automatic i2c_credit_monitor fresh_monitor();
    i2c_credit_monitor result = new("unit_monitor", null);
    result.cfg = new;
    return result;
  endfunction

  function automatic i2c_credit_event_payload payload(
    input i2c_credit_frame_e frame, input int unsigned count, input bit physical = 0);
    i2c_credit_event_payload result = new("unit_payload");
    result.frame_type = frame;
    result.credit_count = count;
    result.physical_release_observed = physical;
    return result;
  endfunction

  task automatic reject_without_update(
    input i2c_credit_monitor mon, input i2c_credit_event_payload candidate,
    input string context_name);
    int balance = mon.shadow_credit_counter;
    longint unsigned initial_grant = mon.total_credits_init;
    longint unsigned consumed = mon.total_credits_consumed;
    longint unsigned returned = mon.total_credits_returned;
    bit initialized = mon.init_complete;
    i2c_credit_state_e state_before = mon.shadow_state;
    int unsigned violations = mon.tbi6_violations;
    require(!mon.apply_credit_return(candidate), {context_name, ": rejected"});
    require(mon.shadow_credit_counter == balance && mon.total_credits_init == initial_grant &&
            mon.total_credits_consumed == consumed && mon.total_credits_returned == returned &&
            mon.init_complete == initialized && mon.shadow_state == state_before,
            {context_name, ": accounting/state unchanged"});
    require(mon.tbi6_violations == violations + 1, {context_name, ": one diagnostic"});
  endtask

  i2c_credit_event_payload producer, cbt, observer, candidate;
  i2c_credit_monitor mon;
  i2c_transaction tr;
  int unsigned epoch_before, tbi1_before, diagnostics_before;
  initial begin
    i2c_event_pool::reset_all_events();
    require(!i2c_event_pool::publish_credit_init(null), "null INIT rejected");
    producer = payload(I2C_CREDIT_FRAME_INIT, 0);
    require(!i2c_event_pool::publish_credit_init(producer), "zero INIT rejected");
    producer.credit_count = 8;
    producer.physical_release_observed = 1;
    require(i2c_event_pool::publish_credit_init(producer), "valid INIT retained");
    producer.credit_count = 1;
    producer.frame_type = I2C_CREDIT_FRAME_DATA;
    producer.physical_release_observed = 0;
    require(i2c_event_pool::try_get_credit_init(I2C_CREDIT_CONSUMER_CBT, cbt), "CBT INIT delivered");
    require(cbt != producer && cbt.credit_count == 8 &&
            cbt.frame_type == I2C_CREDIT_FRAME_INIT && cbt.physical_release_observed,
            "publisher mutation cannot change CBT INIT snapshot");
    cbt.credit_count = 2;
    cbt.physical_release_observed = 0;
    require(i2c_event_pool::try_get_credit_init(I2C_CREDIT_CONSUMER_MONITOR, observer), "monitor INIT delivered");
    require(observer != producer && observer != cbt && observer.credit_count == 8 &&
            observer.physical_release_observed,
            "CBT mutation cannot change monitor INIT snapshot");
    producer = payload(I2C_CREDIT_FRAME_INIT, 8);
    require(!i2c_event_pool::publish_credit_init(producer), "duplicate INIT rejected after both queues drained");
    require(!i2c_event_pool::try_get_credit_init(I2C_CREDIT_CONSUMER_CBT, cbt) && cbt == null,
            "duplicate INIT not queued");

    producer = payload(I2C_CREDIT_FRAME_RETURN, 2, 1);
    require(i2c_event_pool::publish_credit_return(producer), "first RETURN retained");
    producer.credit_count = 1;
    producer.physical_release_observed = 0;
    require(i2c_event_pool::publish_credit_return(producer), "second RETURN retained");
    producer.credit_count = 99;
    require(i2c_event_pool::try_get_credit_return(I2C_CREDIT_CONSUMER_CBT, cbt), "CBT first RETURN");
    require(cbt.credit_count == 2 && cbt.physical_release_observed, "RETURN publisher snapshot");
    cbt.credit_count = 77;
    cbt.physical_release_observed = 0;
    require(i2c_event_pool::try_get_credit_return(I2C_CREDIT_CONSUMER_MONITOR, observer), "monitor first RETURN");
    require(observer != cbt && observer.credit_count == 2 && observer.physical_release_observed,
            "RETURN consumers independent");
    require(i2c_event_pool::try_get_credit_return(I2C_CREDIT_CONSUMER_CBT, cbt) && cbt.credit_count == 1,
            "CBT retained FIFO ordering");
    require(i2c_event_pool::try_get_credit_return(I2C_CREDIT_CONSUMER_MONITOR, observer) &&
            observer.credit_count == 1, "monitor retained FIFO ordering");

    producer = payload(I2C_CREDIT_FRAME_RETURN, I2C_CREDIT_MAX_DEPTH + 1);
    require(!i2c_event_pool::publish_credit_return(producer), "oversized channel RETURN rejected");
    producer = payload(I2C_CREDIT_FRAME_DATA, 1);
    require(!i2c_event_pool::publish_credit_return(producer), "wrong channel RETURN type rejected");
    require(i2c_event_pool::publish_credit_return(payload(I2C_CREDIT_FRAME_RETURN, 1)), "queued before reset");
    epoch_before = i2c_event_pool::reset_epoch;
    i2c_event_pool::reset_all_events();
    require(i2c_event_pool::reset_epoch == epoch_before + 1, "reset epoch increment preserved");
    require(!i2c_event_pool::try_get_credit_return(I2C_CREDIT_CONSUMER_CBT, cbt) &&
            !i2c_event_pool::try_get_credit_return(I2C_CREDIT_CONSUMER_MONITOR, observer),
            "reset clears both retained RETURN queues");
    require(i2c_event_pool::publish_credit_init(payload(I2C_CREDIT_FRAME_INIT, 8)), "new reset epoch permits INIT");
    i2c_event_pool::reset_all_events();
    require(!i2c_event_pool::try_get_credit_init(I2C_CREDIT_CONSUMER_CBT, cbt) &&
            !i2c_event_pool::try_get_credit_init(I2C_CREDIT_CONSUMER_MONITOR, observer),
            "reset clears both retained INIT queues");

    mon = fresh_monitor();
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, 1), "RETURN before INIT");
    require(!mon.apply_credit_init(null) && mon.shadow_credit_counter == 0, "null monitor INIT rejected");
    require(!mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, 0)), "zero monitor INIT rejected");
    require(!mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, 7)), "mismatched monitor INIT rejected");
    require(!mon.apply_credit_init(payload(I2C_CREDIT_FRAME_RETURN, 8)), "wrong monitor INIT type rejected");
    require(mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, 8)), "valid monitor INIT");
    require(!mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, 8)) && mon.shadow_credit_counter == 8 &&
            mon.total_credits_init == 8, "duplicate monitor INIT cannot inflate grant");
    mon = fresh_monitor();
    mon.cfg.cbr_depth = 0;
    require(!mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, 0)) && !mon.init_complete,
            "matching zero-depth INIT is still invalid");
    mon = fresh_monitor();
    mon.cfg.cbr_depth = I2C_CREDIT_MAX_DEPTH + 1;
    require(!mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, I2C_CREDIT_MAX_DEPTH + 1)) &&
            !mon.init_complete, "matching oversized-depth INIT is still invalid");
    mon = fresh_monitor();
    tr = new;
    tr.data = new[1];
    tr.accepted_data_bytes = 1;
    mon.observe_completed_write(tr);
    require(!mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, 8)) &&
            mon.shadow_credit_counter == -1 && mon.total_credits_consumed == 1,
            "late INIT cannot erase pre-initialization acceptance");
    mon = fresh_monitor();
    require(mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, 8)), "monitor reset by fresh accounting instance");

    tr = new;
    tr.data = new[2];
    tr.data[0] = 8'h01;
    tr.data[1] = 8'h48;
    tr.accepted_data_bytes = 2;
    diagnostics_before = test_diagnostics::errors;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 8 && mon.total_credits_consumed == 0 &&
            mon.total_credits_returned == 0 && mon.total_credits_init == 8 &&
            mon.tbi1_violations == 0 && mon.tbi2_violations == 0 && mon.tbi3_violations == 0 &&
            mon.tbi6_violations == 0 && mon.shadow_state == CREDIT_STATE_READY &&
            test_diagnostics::errors == diagnostics_before + 1,
            "mixed DATA/INIT image rejected before any monitor counter/state update");
    tr.data[1] = 8'h80;
    diagnostics_before = test_diagnostics::errors;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 8 && mon.total_credits_consumed == 0 &&
            mon.tbi1_violations == 0 && test_diagnostics::errors == diagnostics_before + 1,
            "later RETURN tag cannot be charged as DATA");
    tr.data[1] = 8'hc0;
    diagnostics_before = test_diagnostics::errors;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 8 && mon.total_credits_consumed == 0 &&
            mon.tbi1_violations == 0 && test_diagnostics::errors == diagnostics_before + 1,
            "later STATUS tag cannot be charged as DATA");
    tr.frame_type = I2C_CREDIT_FRAME_INIT;
    tr.credit_count = 8;
    tr.data[0] = 8'h48;
    tr.data[1] = 8'h01;
    diagnostics_before = test_diagnostics::errors;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 8 && mon.total_credits_consumed == 0 &&
            mon.tbi1_violations == 0 && test_diagnostics::errors == diagnostics_before + 1,
            "control-first mixed image rejected before control filtering");
    tr.frame_type = I2C_CREDIT_FRAME_DATA;
    tr.data = new[0];
    tr.accepted_data_bytes = 0;
    diagnostics_before = test_diagnostics::errors;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 8 && mon.total_credits_consumed == 0 &&
            mon.tbi1_violations == 0 && test_diagnostics::errors == diagnostics_before + 1,
            "empty DATA image rejected without debit");
    tr = new;
    tr.data = new[2];
    tr.accepted_data_bytes = 2;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 6 && mon.total_credits_consumed == 2, "ACK-qualified completion debit");
    mon.check_phase(null);
    require(mon.tbi4_balance_delta == 0, "valid outstanding accepted bytes preserve conservation without a RETURN");
    mon.shadow_credit_counter = 5;
    mon.check_phase(null);
    require(mon.tbi4_balance_delta == -1, "negative conservation residual remains signed");
    mon.shadow_credit_counter = 7;
    mon.check_phase(null);
    require(mon.tbi4_balance_delta == 1, "positive conservation residual diagnosed");
    mon.shadow_credit_counter = 6;
    reject_without_update(mon, null, "null RETURN");
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_DATA, 1), "wrong RETURN type");
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, 0), "zero RETURN");
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, I2C_CREDIT_MAX_DEPTH + 1), "oversized RETURN");
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, 32'hffffffff), "unsigned extreme RETURN");
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, 9), "RETURN larger than depth");
    require(mon.apply_credit_return(payload(I2C_CREDIT_FRAME_RETURN, 2)), "valid release-unproven ordering RETURN");
    require(mon.shadow_credit_counter == 8 && mon.total_credits_returned == 2, "valid RETURN applied once");
    mon.check_phase(null);
    require(mon.tbi4_balance_delta == 0, "returned balance preserves conservation");
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, 1), "surplus RETURN after balance restored");

    mon.shadow_credit_counter = 1;
    mon.total_credits_consumed = 64'h100000007;
    mon.total_credits_returned = 64'h100000000;
    mon.check_phase(null);
    require(mon.tbi4_balance_delta == 0, "cumulative accounting does not wrap at 32 bits");
    require(mon.apply_credit_return(payload(I2C_CREDIT_FRAME_RETURN, 1)) &&
            mon.total_credits_returned == 64'h100000001 && mon.shadow_credit_counter == 2,
            "wide cumulative valid RETURN remains atomic");

    // Construct separate counter/cumulative states to isolate each guard.
    mon.shadow_credit_counter = 4;
    mon.total_credits_consumed = 2;
    mon.total_credits_returned = 0;
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, 3), "accepted-count bound without counter overflow");
    mon.shadow_credit_counter = 7;
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, 2), "counter overflow with sufficient accepted count");
    mon.shadow_credit_counter = -1;
    reject_without_update(mon, payload(I2C_CREDIT_FRAME_RETURN, 1), "RETURN must not repair an invalid negative balance");

    mon = fresh_monitor();
    require(mon.apply_credit_init(payload(I2C_CREDIT_FRAME_INIT, 8)), "fresh completion monitor INIT");
    tr = new;
    tr.data = new[1];
    tr.accepted_data_bytes = 0;
    tr.status = I2C_STATUS_DATA_NACK;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 8 && mon.total_credits_consumed == 0, "NACK consumes no credit");
    tr.accepted_data_bytes = 2;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 8 && mon.total_credits_consumed == 0, "malformed accepted count rejected");
    tr.accepted_data_bytes = 1;
    tr.direction = I2C_READ;
    mon.observe_completed_write(tr);
    tr.direction = I2C_WRITE;
    tr.frame_type = I2C_CREDIT_FRAME_INIT;
    tr.credit_count = 8;
    tr.data[0] = 8'h48;
    mon.observe_completed_write(tr);
    tr.frame_type = I2C_CREDIT_FRAME_DATA;
    tr.credit_count = 0;
    tr.data[0] = 8'h01;
    tr.status = I2C_STATUS_ADDR_NACK;
    mon.observe_completed_write(tr);
    require(mon.shadow_credit_counter == 8 && mon.total_credits_consumed == 0, "read/control/address-NACK excluded");

    mon.shadow_credit_counter = 0;
    mon.total_credits_consumed = 8;
    tr.status = I2C_STATUS_DATA_NACK;
    tr.accepted_data_bytes = 0;
    tbi1_before = mon.tbi1_violations;
    mon.observe_completed_write(tr);
    require(mon.tbi1_violations == tbi1_before + 1, "completion-time deficit diagnosed");
    tbi1_before = mon.tbi1_violations;
    require(mon.apply_credit_return(payload(I2C_CREDIT_FRAME_RETURN, 1)), "intervening accepted-backed RETURN");
    tr.status = I2C_STATUS_OK;
    tr.accepted_data_bytes = 1;
    mon.observe_completed_write(tr);
    require(mon.tbi1_violations == tbi1_before && mon.shadow_credit_counter == 0,
            "documented limitation: intervening RETURN masks a launch-time deficit");
    mon.check_phase(null);
    require(mon.tbi4_balance_delta == 0, "conservation does not establish launch authorization");
    require(mon.tbi5_violations == 0, "monitor has no TBI-5 watchdog observation");
    $display("KNOWN_LIMITATION: completion-time observation cannot independently establish launch authorization; TBI-5 unscored; physical releases unobserved");
    $display("PASS tb_credit_events checks=%0d: isolated source-derived snapshot/epoch and atomic monitor-accounting functions", checks);
    $finish;
  end
endmodule
