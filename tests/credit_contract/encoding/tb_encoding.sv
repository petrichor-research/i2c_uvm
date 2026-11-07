`timescale 1ns/1ps
module tb;
  // COMMON
  // SOURCE_METHODS
  integer cases = 0, before_type;
  bit [7:0] before_byte;
  integer unsigned invalid_counts [0:3];

  initial begin
    // Every six-bit DATA value must survive, independently of credit_count.
    for (integer value = 0; value < 64; value = value + 1) begin
      reset_item();
      data = new[1]; data[0] = value;
      credit_count = 63;
      if (!encode_credit_header() || !valid_credit_encoding() || data[0] !== value)
        $fatal(1, "DATA payload was overwritten: value=%0d actual=%h", value, data[0]);
      cases = cases + 1;
    end

    // Reject rather than truncate every unencodable eight-bit DATA value.
    for (integer value = 64; value < 256; value = value + 1) begin
      reset_item();
      data = new[1]; data[0] = value;
      is_credit_init = 1; is_credit_return = 1;
      if (encode_credit_header() || valid_credit_encoding() || data[0] !== value ||
          !is_credit_init || !is_credit_return)
        $fatal(1, "Invalid DATA was mutated or accepted: value=%0d", value);
      cases = cases + 1;
    end

    reset_item(); data = new[4];
    data[0] = 0; data[1] = 1; data[2] = 35; data[3] = 63;
    if (!encode_credit_header() || !valid_credit_encoding() ||
        data[0] != 0 || data[1] != 1 || data[2] != 35 || data[3] != 63)
      $fatal(1, "Multibyte DATA changed");
    cases = cases + 1;
    for (integer position = 0; position < 4; position = position + 1) begin
      data[position] = 8'h80;
      if (encode_credit_header() || valid_credit_encoding() || data[position] !== 8'h80)
        $fatal(1, "Non-DATA tag accepted in a multibyte DATA request");
      data[position] = 0;
      cases = cases + 1;
    end
    reset_item();
    if (encode_credit_header() || valid_credit_encoding() || data.size() != 0)
      $fatal(1, "Empty DATA manufactured a header/payload byte");
    cases = cases + 1;

    // INIT, RETURN, and STATUS all have an explicit six-bit control count.
    for (integer kind = 1; kind <= 3; kind = kind + 1) begin
      for (integer count = 1; count <= 63; count = count + 1) begin
        reset_item(); frame_type = kind; credit_count = count;
        if (!encode_credit_header() || !valid_credit_encoding() || data.size() != 1 ||
            data[0] !== ((kind << 6) | count))
          $fatal(1, "Control encoding mismatch: type=%0d count=%0d", kind, count);
        frame_type = 0; credit_count = 0;
        decode_credit_header();
        if (frame_type != kind || credit_count != count ||
            is_credit_init != (kind == 1) || is_credit_return != (kind == 2))
          $fatal(1, "Control round-trip mismatch");
        cases = cases + 1;
      end
    end

    invalid_counts[0] = 0; invalid_counts[1] = 64;
    invalid_counts[2] = 256; invalid_counts[3] = 32'hFFFFFFFF;
    foreach (invalid_counts[i]) begin
      reset_item(); frame_type = I2C_CREDIT_FRAME_INIT;
      credit_count = invalid_counts[i]; data = new[1]; data[0] = 8'hAA;
      if (encode_credit_header() || valid_credit_encoding() || data[0] !== 8'hAA)
        $fatal(1, "Invalid control count changed data or was accepted");
      cases = cases + 1;
      data = new[0];
      if (encode_credit_header() || data.size() != 0)
        $fatal(1, "Invalid control count allocated a wire byte");
      cases = cases + 1;
    end
    reset_item(); frame_type = I2C_CREDIT_FRAME_RETURN; credit_count = 1;
    data = new[2]; data[0] = 8'h12; data[1] = 8'h34;
    if (encode_credit_header() || valid_credit_encoding() || data[0] !== 8'h12 || data[1] !== 8'h34)
      $fatal(1, "Multibyte control request was silently rewritten");
    cases = cases + 1;
    $display("PASS encoding cases=%0d DATA_0..63_preserved DATA_64..255_rejected multibyte_tags control_1..63", cases);
    $finish;
  end
endmodule
