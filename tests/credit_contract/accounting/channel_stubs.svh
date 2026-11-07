  localparam I2C_CREDIT_FRAME_DATA = 0, I2C_CREDIT_FRAME_INIT = 1;
  localparam I2C_CREDIT_FRAME_RETURN = 2, I2C_CREDIT_FRAME_STATUS = 3;
  localparam I2C_CREDIT_CONSUMER_CBT = 0, I2C_CREDIT_CONSUMER_MONITOR = 1;
  localparam I2C_CREDIT_MAX_DEPTH = 256;
  localparam CREDIT_STATE_RESET = 0, CREDIT_STATE_INIT = 1, CREDIT_STATE_READY = 2;
  localparam CREDIT_STATE_ACTIVE = 3, CREDIT_STATE_EXHAUSTED = 4, CREDIT_STATE_ERROR = 5;
  localparam I2C_STATUS_OK = 0, I2C_STATUS_ADDR_NACK = 1, I2C_STATUS_DATA_NACK = 2;
  localparam I2C_STATUS_TIMEOUT = 3, I2C_STATUS_ARB_LOST = 4, I2C_STATUS_ERROR = 5;
  localparam I2C_WRITE = 0, I2C_READ = 1;
  localparam I2C_CREDIT_FRAME_TYPE_MSB = 7, I2C_CREDIT_FRAME_TYPE_LSB = 6;
  localparam I2C_CREDIT_PAYLOAD_MSB = 5, I2C_CREDIT_PAYLOAD_LSB = 0;
  integer cfg_cbr_depth = 8, cfg_cbr_pipe_delay = 2;
  integer cfg_credit_stall_timeout_ns = 100, cfg_credit_init_timeout_ns = 100;
  integer cfg_credit_return_timeout_ns = 100;
  bit cfg_is_master = 1, cfg_inject_send_without_credit = 0;
  bit cfg_inject_phantom_credit = 0, cfg_inject_init_glitch = 0;
  bit cfg_credit_mode_enable = 1;
  integer reset_epoch = 0;
  integer payload_frame_type [0:255], payload_credit_count [0:255];
  integer payload_epoch [0:255], payload_reset_epoch [0:255];
  bit payload_physical_release_observed [0:255];
  integer next_payload = 1;
  integer payload;
  integer init_queue [$], return_queue [$];
  event channel_hint;
  integer transaction_direction [0:7], transaction_frame_type [0:7];
  integer transaction_status [0:7], transaction_accepted_data_bytes [0:7];
  integer transaction_size [0:7], transaction_addr [0:7];
  integer transaction_credit_count [0:7];
  bit transaction_nack_received [0:7];
  reg [7:0] transaction_data [0:7][0:31];
  bit publication_allowed = 1;
  integer publications = 0, published_credits = 0;
  bit published_physical_release = 0;

  function automatic integer new_payload();
    integer handle;
    handle = next_payload;
    next_payload = next_payload + 1;
    if (next_payload >= 256) $fatal(1, "Payload stub storage exhausted");
    payload_frame_type[handle] = I2C_CREDIT_FRAME_DATA;
    payload_credit_count[handle] = 0;
    payload_epoch[handle] = reset_epoch;
    payload_reset_epoch[handle] = reset_epoch;
    payload_physical_release_observed[handle] = 0;
    return handle;
  endfunction

  function automatic integer make_payload(input integer kind, input integer count);
    integer handle;
    handle = new_payload();
    payload_frame_type[handle] = kind;
    payload_credit_count[handle] = count;
    return handle;
  endfunction

  function automatic bit channel_valid_credit_payload(input integer payload, input integer expected_type);
    return payload != 0 && payload_frame_type[payload] == expected_type &&
           payload_credit_count[payload] > 0 && payload_credit_count[payload] <= I2C_CREDIT_MAX_DEPTH;
  endfunction

  function automatic bit channel_try_get_credit_init(input integer consumer);
    payload = 0;
    if (init_queue.size() == 0) return 0;
    payload = init_queue.pop_front();
    return 1;
  endfunction

  function automatic bit channel_try_get_credit_return(input integer consumer);
    payload = 0;
    if (return_queue.size() == 0) return 0;
    payload = return_queue.pop_front();
    return 1;
  endfunction

  function automatic bit channel_publish_credit_return(input integer payload);
    if (!publication_allowed || !channel_valid_credit_payload(payload, I2C_CREDIT_FRAME_RETURN)) return 0;
    publications = publications + 1;
    published_credits = published_credits + payload_credit_count[payload];
    published_physical_release = payload_physical_release_observed[payload];
    return 1;
  endfunction

  function automatic integer channel_get_credit_return_available_event(input integer consumer);
    return 0;
  endfunction

  function automatic void channel_trigger_event(input string event_name);
  endfunction

  task channel_wait_for_credit_return_timeout(
    input integer consumer, input time timeout, output bit timed_out, output integer payload);
    timed_out = 0;
    payload = 0;
    fork
      begin
        while (return_queue.size() == 0) @(channel_hint);
        payload = return_queue.pop_front();
      end
      begin #timeout; timed_out = 1; end
    join_any
    disable fork;
  endtask

  task automatic queue_return(input integer count);
    integer handle;
    handle = make_payload(I2C_CREDIT_FRAME_RETURN, count);
    return_queue.push_back(handle);
    ->channel_hint;
  endtask

  task automatic clear_channels();
    init_queue.delete();
    return_queue.delete();
    publication_allowed = 1;
  endtask
