`timescale 1ns/1ps

module tb;
  // CHANNEL_STUBS
  integer credit_counter = 8, credit_state = CREDIT_STATE_READY;
  longint unsigned total_data_received = 0, total_credits_returned = 0, total_credits_initialized = 8;
  longint signed conservation_residual = 0;
  integer cr_return_pipe [$], cr_return_epoch_pipe [$];
  integer credit_epoch = 0;
  bit init_complete = 1;
  integer cases = 0, before_counter, before_publications;
  longint unsigned before_returned;
  bit ok;

  // SOURCE_METHODS

  task automatic ready();
    clear_channels();
    cfg_is_master = 0;
    cfg_cbr_depth = 8;
    cfg_inject_phantom_credit = 0;
    cfg_inject_init_glitch = 0;
    cfg_credit_mode_enable = 1;
    credit_counter = 8;
    total_data_received = 0;
    total_credits_returned = 0;
    total_credits_initialized = 8;
    conservation_residual = 0;
    credit_epoch = reset_epoch;
    init_complete = 1;
    cr_return_pipe.delete();
    cr_return_epoch_pipe.delete();
    transaction_direction[1] = I2C_WRITE;
    transaction_frame_type[1] = I2C_CREDIT_FRAME_DATA;
    transaction_status[1] = I2C_STATUS_OK;
    transaction_accepted_data_bytes[1] = 2;
    transaction_size[1] = 2;
    transaction_addr[1] = 7'h55;
    transaction_data[1][0] = 8'h10;
    transaction_data[1][1] = 8'h25;
  endtask

  task automatic no_consumption(input integer handle, input bit serviced);
    ok = account_received_transaction(handle, serviced);
    if (credit_counter != 8 || total_data_received != 0 || cr_return_pipe.size() != 0)
      $fatal(1, "Non-consuming result changed receiver accounting");
    cases = cases + 1;
  endtask

  task automatic reject_publication(input integer count, input integer expected_epoch);
    before_counter = credit_counter;
    before_returned = total_credits_returned;
    before_publications = publications;
    if (publish_return(count, expected_epoch) || credit_counter != before_counter ||
        total_credits_returned != before_returned || publications != before_publications)
      $fatal(1, "Rejected CBR publication changed accounting/channel: count=%0d", count);
    cases = cases + 1;
  endtask

  initial begin
    ready();
    no_consumption(0, 0);
    no_consumption(1, 0);
    transaction_direction[1] = I2C_READ;
    no_consumption(1, 1);
    transaction_direction[1] = I2C_WRITE;
    transaction_frame_type[1] = I2C_CREDIT_FRAME_INIT;
    no_consumption(1, 1);
    transaction_frame_type[1] = I2C_CREDIT_FRAME_RETURN;
    no_consumption(1, 1);
    transaction_frame_type[1] = I2C_CREDIT_FRAME_DATA;
    transaction_status[1] = I2C_STATUS_ADDR_NACK;
    no_consumption(1, 1);
    transaction_status[1] = I2C_STATUS_OK;
    cfg_is_master = 1;
    no_consumption(1, 1);

    // Contradictory metadata/wire tag and impossible ACK counts reject before
    // changing capacity or scheduling a return.
    ready();
    transaction_data[1][0] = 8'h40;
    if (account_received_transaction(1, 1) || credit_counter != 8 || cr_return_pipe.size() != 0)
      $fatal(1, "Control-tagged wire byte consumed DATA budget");
    transaction_data[1][0] = 8'h10;
    transaction_data[1][1] = 8'h80;
    if (account_received_transaction(1, 1) || credit_counter != 8 ||
        total_data_received != 0 || cr_return_pipe.size() != 0)
      $fatal(1, "Later non-DATA wire tag consumed DATA budget");
    transaction_data[1][1] = 8'h25;
    cases = cases + 1;
    transaction_accepted_data_bytes[1] = 3;
    if (account_received_transaction(1, 1) || credit_counter != 8 || cr_return_pipe.size() != 0)
      $fatal(1, "Accepted count larger than observed bytes consumed budget");
    cases = cases + 1;

    ready();
    transaction_accepted_data_bytes[1] = 1;
    transaction_status[1] = I2C_STATUS_DATA_NACK;
    if (!account_received_transaction(1, 1) || credit_counter != 7 ||
        total_data_received != 1 || cr_return_pipe.size() != 1)
      $fatal(1, "Partial-NACK transaction lost its prior ACK-qualified byte");
    cases = cases + 1;

    ready();
    if (!account_received_transaction(1, 1) || credit_counter != 6 || total_data_received != 2 || cr_return_pipe.size() != 2)
      $fatal(1, "ACK-qualified multibyte write was not counted once per byte");
    check_phase(0);
    if (conservation_residual != 0)
      $fatal(1, "Pending accepted bytes caused a false conservation failure");
    credit_counter = 5;
    check_phase(0);
    if (conservation_residual != -1)
      $fatal(1, "Negative CBR conservation residual lost its sign");
    credit_counter = 7;
    cfg_inject_phantom_credit = 1;
    cfg_inject_init_glitch = 1;
    check_phase(0);
    if (conservation_residual != 1)
      $fatal(1, "Injection knobs waived a real CBR conservation error");
    credit_counter = 6;
    cfg_inject_phantom_credit = 0;
    cfg_inject_init_glitch = 0;
    cases = cases + 1;

    reject_publication(0, credit_epoch);
    reject_publication(I2C_CREDIT_MAX_DEPTH + 1, credit_epoch);
    reject_publication(cfg_cbr_depth + 1, credit_epoch);
    reject_publication(1, credit_epoch + 1);
    publication_allowed = 0;
    reject_publication(1, credit_epoch);
    publication_allowed = 1;
    if (!publish_return(2, credit_epoch) || credit_counter != 8 || total_credits_returned != 2 ||
        published_credits != 2 || published_physical_release)
      $fatal(1, "Validated CBR publication did not commit exactly once");
    check_phase(0);
    if (conservation_residual != 0)
      $fatal(1, "Balanced CBR return violated conservation");
    cases = cases + 1;
    reject_publication(1, credit_epoch);

    ready();
    credit_counter = 1;
    total_data_received = 64'h100000007;
    total_credits_returned = 64'h100000000;
    check_phase(0);
    if (conservation_residual != 0 || !publish_return(1, credit_epoch) ||
        total_credits_returned != 64'h100000001 || credit_counter != 2)
      $fatal(1, "Wide CBR cumulative accounting wrapped at 32 bits");
    cases = cases + 1;

    ready();
    if (!account_received_transaction(1, 1)) $fatal(1, "Reset fixture was not accounted");
    reset_epoch = reset_epoch + 1;
    if (publish_return(1, credit_epoch) || init_complete || credit_counter != 0 ||
        cr_return_pipe.size() != 0 || total_credits_returned != 0)
      $fatal(1, "Reset did not invalidate/clear delayed receiver accounting");
    cases = cases + 1;

    $display("PASS cbr_accounting cases=%0d qualification ACK_bytes invalid_publication atomic_commit", cases);
    $finish;
  end

  initial begin
    #5000;
    $fatal(1, "CBR accounting watchdog expired");
  end
endmodule
