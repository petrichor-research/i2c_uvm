`timescale 1ns/1ps

module tb;
  // CHANNEL_STUBS
  integer credit_counter = 0, credit_state = CREDIT_STATE_RESET;
  integer total_data_sent = 0, total_stall_cycles = 0, total_credits_received = 0;
  bit init_complete = 0;
  integer credit_epoch = 0, wait_failure_status = I2C_STATUS_OK;
  integer cases = 0, before_counter, before_received, event_handle;
  bit ok;
  time started, elapsed;

  // SOURCE_METHODS

  task automatic ready(input integer balance);
    clear_channels();
    cfg_is_master = 1;
    cfg_inject_send_without_credit = 0;
    cfg_cbr_depth = 8;
    cfg_credit_stall_timeout_ns = 100;
    credit_epoch = reset_epoch;
    init_complete = 1;
    credit_counter = balance;
    total_credits_received = 8;
    total_data_sent = 8 - balance;
    total_stall_cycles = 0;
    wait_failure_status = I2C_STATUS_OK;
    update_credit_state();
  endtask

  task automatic reject_count(input integer count);
    before_counter = credit_counter;
    before_received = total_credits_received;
    if (receive_credit(count) || credit_counter != before_counter || total_credits_received != before_received)
      $fatal(1, "Rejected RETURN changed accounting: count=%0d balance=%0d", count, credit_counter);
    cases = cases + 1;
  endtask

  initial begin
    ready(4);
    reject_count(0);
    reject_count(I2C_CREDIT_MAX_DEPTH + 1);
    reject_count(cfg_cbr_depth + 1);
    reject_count(32'h80000001);
    reject_count(32'hFFFFFFFF);
    ready(8);
    reject_count(1);

    // Free counter space alone is not evidence of an outstanding ACKed byte.
    ready(4);
    total_data_sent = 1;
    reject_count(2);
    ready(4);
    init_complete = 0;
    reject_count(1);
    ready(4);
    credit_epoch = reset_epoch + 1;
    reject_count(1);

    ready(4);
    if (apply_credit_return(0)) $fatal(1, "Null RETURN handle was accepted");
    event_handle = make_payload(I2C_CREDIT_FRAME_INIT, 1);
    if (apply_credit_return(event_handle) || credit_counter != 4 || total_credits_received != 8)
      $fatal(1, "Wrong-type RETURN changed accounting");
    cases = cases + 1;

    ready(4);
    queue_return(2);
    if (!drain_credit_channels() || credit_counter != 6 || total_credits_received != 10 || return_queue.size() != 0)
      $fatal(1, "Positive-balance queued RETURN was not drained exactly once");
    if (!drain_credit_channels() || credit_counter != 6 || total_credits_received != 10)
      $fatal(1, "Second drain reapplied a consumed RETURN");
    cases = cases + 1;

    ready(4);
    wait_for_credit(0, ok);
    if (ok || credit_counter != 4 || wait_failure_status == I2C_STATUS_OK)
      $fatal(1, "Zero-byte DATA request was permitted");
    wait_for_credit(9, ok);
    if (ok || credit_counter != 4 || wait_failure_status == I2C_STATUS_OK)
      $fatal(1, "Over-depth DATA request was permitted");
    cases = cases + 1;

    ready(4);
    event_handle = make_payload(I2C_CREDIT_FRAME_INIT, 8);
    init_queue.push_back(event_handle);
    if (drain_credit_channels() || credit_counter != 4 || total_credits_received != 8)
      $fatal(1, "Duplicate INIT was accepted or mutated credit accounting");
    cases = cases + 1;

    // Two partial returns do not restart the original 100 ns deadline.
    ready(0);
    started = $time;
    fork
      wait_for_credit(3, ok);
      begin #40; queue_return(1); #40; queue_return(1); end
    join
    elapsed = $time - started;
    if (ok || elapsed != 100 || wait_failure_status != I2C_STATUS_TIMEOUT || credit_counter != 2)
      $fatal(1, "Stall deadline restarted/incorrect: ok=%b elapsed=%0t status=%0d credits=%0d", ok, elapsed, wait_failure_status, credit_counter);
    cases = cases + 1;

    ready(0);
    started = $time;
    fork
      wait_for_credit(1, ok);
      begin #25; cfg_is_master = 0; end
    join
    if (ok || $time - started != 25 || wait_failure_status == I2C_STATUS_OK || credit_counter != 0)
      $fatal(1, "Role change did not cancel blocked dispatch promptly");
    cases = cases + 1;

    ready(0);
    started = $time;
    fork
      wait_for_credit(1, ok);
      begin #25; reset_epoch = reset_epoch + 1; end
    join
    if (ok || $time - started != 25 || wait_failure_status == I2C_STATUS_OK || credit_counter != 0)
      $fatal(1, "Reset did not cancel blocked dispatch promptly");
    cases = cases + 1;

    $display("PASS cbt_accounting cases=%0d invalid_counts positive_drain duplicate_INIT absolute_deadline role/reset_abort", cases);
    $finish;
  end

  initial begin
    #5000;
    $fatal(1, "CBT accounting watchdog expired");
  end
endmodule
