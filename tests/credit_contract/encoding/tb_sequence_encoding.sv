`timescale 1ns/1ps
module tb;
  // COMMON
  // SOURCE_METHODS
  bit [7:0] payload[];
  integer before_starts, before_finishes, cases = 0;

  initial begin
    payload = new[1]; payload[0] = 8'h35;
    send_data_frame(payload, 7);
    if (starts != 1 || finishes != 1 || outstanding != 0 ||
        last_finished_size != 1 || last_finished_data[0] !== 8'h35)
      $fatal(1, "DATA sequence lost payload or grant pairing");
    cases = cases + 1;

    before_starts = starts; before_finishes = finishes;
    payload[0] = 8'hDE;
    send_data_frame(payload);
    payload = new[0]; send_data_frame(payload);
    payload = new[2]; payload[0] = 1; payload[1] = 8'h40;
    send_data_frame(payload);
    if (starts != before_starts || finishes != before_finishes || outstanding != 0)
      $fatal(1, "Encoding failure acquired/leaked a sequencer grant");
    cases = cases + 3;

    cfg_depth = 8; run_init();
    if (starts != before_starts + 1 || finishes != before_finishes + 1 ||
        last_finished_data[0] !== 8'h48 || outstanding != 0)
      $fatal(1, "INIT sequence encoding/lifecycle mismatch");
    cases = cases + 1;
    before_starts = starts; before_finishes = finishes;
    cfg_depth = 256; run_init();
    if (starts != before_starts || finishes != before_finishes || outstanding != 0)
      $fatal(1, "Unencodable wire INIT acquired a grant");
    cases = cases + 1;

    // Actual sequence bodies generate only encodable DATA values. The start
    // stub validates every complete image, including all bytes, before grant.
    cfg_depth = 8;
    before_finishes = finishes;
    run_data();
    if (finishes != before_finishes + num_frames) $fatal(1, "Data sequence did not complete");
    cases = cases + 1;
    before_finishes = finishes;
    run_burst();
    if (finishes != before_finishes + burst_count * burst_size) $fatal(1, "Burst sequence did not complete");
    cases = cases + 1;
    before_finishes = finishes;
    run_exhaustion();
    if (finishes != before_finishes + cfg_depth + cfg_depth / 2) $fatal(1, "Exhaustion sequence did not complete");
    cases = cases + 1;
    before_finishes = finishes;
    run_error_data();
    if (finishes != before_finishes + cfg_depth + 3 || last_finished_data[0] !== 8'h1E)
      $fatal(1, "Budget fault scenario sent an encoding fault instead");
    cases = cases + 1;
    before_finishes = finishes;
    run_phantom();
    if (finishes != before_finishes + cfg_depth / 2 + 1 || last_finished_data[0] !== 8'h85)
      $fatal(1, "Phantom-control sequence encoding/lifecycle mismatch");
    cases = cases + 1;
    before_finishes = finishes;
    run_glitch_data();
    if (finishes != before_finishes + cfg_depth) $fatal(1, "Init-glitch DATA sequence did not complete");
    cases = cases + 1;
    if (starts != finishes || outstanding != 0) $fatal(1, "Sequence lifecycle imbalance");
    $display("PASS sequence_encoding cases=%0d starts=%0d finishes=%0d no_grant_on_encode_failure", cases, starts, finishes);
    $finish;
  end
  initial begin
    #30000; $fatal(1, "Encoding-sequence watchdog expired");
  end
endmodule
