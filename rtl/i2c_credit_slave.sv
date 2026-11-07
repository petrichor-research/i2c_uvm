`timescale 1ns/1ps

module i2c_credit_slave #(
  parameter logic [6:0] SLAVE_ADDR  = 7'h55,
  parameter int         FIFO_DEPTH  = 8,
  // Compatibility knob only: autonomous release/RETURN timing is unsupported.
  parameter int         PIPE_DELAY  = 2
)(
  input  wire scl_i,
  input  wire sda_i,
  output wire scl_o,
  output wire sda_o,
  output wire scl_oe,
  output wire sda_oe,
  input  wire rst_n,

  // Local free-slot status only; this is not a transported RETURN count.
  output logic [7:0] credit_counter,
  output logic [7:0] fifo_occupancy,
  output logic       credit_init_done,
  output logic       fifo_full,
  output logic       fifo_empty
);

  // Keep the behavioral endpoint independent of the UVM package.  These
  // values mirror the wire encoding in i2c_credit_types.sv.
  localparam logic [1:0] CREDIT_FRAME_DATA   = 2'b00;
  localparam logic [1:0] CREDIT_FRAME_INIT   = 2'b01;
  localparam int         CREDIT_FRAME_TYPE_MSB = 7;
  localparam int         CREDIT_FRAME_TYPE_LSB = 6;

  // FSM
  typedef enum logic [3:0] {
    IDLE,
    ADDR,
    ACK_ADDR,
    DATA_RX,
    ACK_DATA_RX,
    DATA_TX,
    ACK_DATA_TX,
    CREDIT_INIT,
    CREDIT_RETURN,
    STOP
  } state_t;

  state_t state;

  // Internal registers
  logic [7:0] shift_reg;
  logic [3:0] bit_cnt;
  logic       rw_bit;
  logic       addr_match;

  // FIFO storage
  logic [7:0] fifo_mem [0:FIFO_DEPTH-1];
  logic [$clog2(FIFO_DEPTH):0] wr_ptr;
  logic [$clog2(FIFO_DEPTH):0] rd_ptr;

  // Prepare the ACK on a falling edge, but commit only at its rising edge.
  logic rx_pending_enqueue;
  logic rx_pending_init;

  // Tri-state control
  logic sda_out_reg;
  logic scl_toggle_reg;

  assign sda_o  = sda_out_reg;
  assign sda_oe = !sda_out_reg;
  assign scl_o  = scl_toggle_reg;
  assign scl_oe = scl_toggle_reg;

  // FIFO status
  assign fifo_full  = (fifo_occupancy >= FIFO_DEPTH);
  assign fifo_empty = (fifo_occupancy == 0);
  assign credit_counter = 8'(FIFO_DEPTH) - fifo_occupancy;

  initial begin
    if (FIFO_DEPTH < 1 || FIFO_DEPTH > 255)
      $fatal(1, "FIFO_DEPTH must fit the byte-wide occupancy status (1..255)");
    if (PIPE_DELAY != 0)
      $warning("PIPE_DELAY is unsupported: only completed FIFO reads release entries; no autonomous release/RETURN path exists");
  end

  // Start condition detection
  always @(negedge sda_i) begin
    if (rst_n && scl_i) begin
      state <= ADDR;
      bit_cnt <= 8;
      shift_reg <= 0;
      sda_out_reg <= 1;
    end
  end

  // Stop condition detection
  always @(posedge sda_i) begin
    if (rst_n && scl_i) begin
      state <= IDLE;
    end
  end

  // Data sampling on SCL rising edge
  always @(posedge scl_i or negedge rst_n) begin
    if (!rst_n) begin
      fifo_occupancy <= 0;
      wr_ptr <= 0;
      rd_ptr <= 0;
      credit_init_done <= 0;
    end else begin
      case (state)
        ADDR: begin
          shift_reg[bit_cnt] <= sda_i;
        end
        DATA_RX: begin
          shift_reg[bit_cnt] <= sda_i;
        end
        ACK_DATA_RX: begin
          if (sda_i == 1'b0) begin
            if (rx_pending_enqueue) begin
              fifo_mem[wr_ptr] <= shift_reg;
              wr_ptr <= (wr_ptr + 1) % FIFO_DEPTH;
              fifo_occupancy <= fifo_occupancy + 1;
            end
            if (rx_pending_init)
              credit_init_done <= 1;
          end
        end
        ACK_DATA_TX: begin
          // ACK and final NACK both complete the byte just transmitted.
          if (!fifo_empty) begin
            rd_ptr <= (rd_ptr + 1) % FIFO_DEPTH;
            fifo_occupancy <= fifo_occupancy - 1;
          end
          if (sda_i == 1'b1)
            state <= IDLE;
        end
      endcase
    end
  end

  // FSM on SCL falling edge
  always @(negedge scl_i or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      sda_out_reg <= 1;
      scl_toggle_reg <= 1;
      bit_cnt <= 0;
      rx_pending_enqueue <= 0;
      rx_pending_init <= 0;
    end else begin
      case (state)
        IDLE: begin
          sda_out_reg <= 1;
        end

        ADDR: begin
          if (bit_cnt == 0) begin
            if (shift_reg[7:1] == SLAVE_ADDR) begin
              addr_match = 1;
              rw_bit = shift_reg[0];
              state <= ACK_ADDR;
              sda_out_reg <= 0;
            end else begin
              addr_match = 0;
              state <= IDLE;
            end
          end else begin
            bit_cnt <= bit_cnt - 1;
            sda_out_reg <= 1;
          end
        end

        ACK_ADDR: begin
          sda_out_reg <= 1;
          scl_toggle_reg <= 0;
          bit_cnt <= 7;
          if (rw_bit == 0) begin
            state <= DATA_RX;
          end else begin
            state <= DATA_TX;
            if (!fifo_empty) begin
              shift_reg <= fifo_mem[rd_ptr];
              sda_out_reg <= fifo_mem[rd_ptr][7];
            end else begin
              shift_reg <= 8'hFF;
              sda_out_reg <= 1;
            end
          end
        end

        DATA_RX: begin
          if (bit_cnt == 0) begin
            // Decode this one-byte frame and prepare ACK/NACK without enqueue.
            rx_pending_enqueue <= 0;
            rx_pending_init <= 0;
            if (shift_reg[CREDIT_FRAME_TYPE_MSB:CREDIT_FRAME_TYPE_LSB] == CREDIT_FRAME_INIT) begin
              rx_pending_init <= 1;
              sda_out_reg <= 0;
              state <= ACK_DATA_RX;
            end else if (shift_reg[CREDIT_FRAME_TYPE_MSB:CREDIT_FRAME_TYPE_LSB] == CREDIT_FRAME_DATA) begin
              if (!fifo_full) begin
                rx_pending_enqueue <= 1;
                sda_out_reg <= 0;
              end else begin
                sda_out_reg <= 1; // NACK: FIFO full
              end
              state <= ACK_DATA_RX;
            end else begin
              sda_out_reg <= 0;
              state <= ACK_DATA_RX;
            end
            scl_toggle_reg <= 1;
          end else begin
            bit_cnt <= bit_cnt - 1;
            sda_out_reg <= 1;
          end
        end

        ACK_DATA_RX: begin
          rx_pending_enqueue <= 0;
          rx_pending_init <= 0;
          sda_out_reg <= 1;
          scl_toggle_reg <= 0;
          bit_cnt <= 7;
          state <= DATA_RX;
        end

        DATA_TX: begin
          if (bit_cnt == 0) begin
            state <= ACK_DATA_TX;
            sda_out_reg <= 1;
          end else begin
            bit_cnt <= bit_cnt - 1;
            sda_out_reg <= shift_reg[bit_cnt - 1];
          end
        end

        ACK_DATA_TX: begin
          state <= DATA_TX;
          if (!fifo_empty) begin
            shift_reg <= fifo_mem[rd_ptr];
            sda_out_reg <= fifo_mem[rd_ptr][7];
          end else begin
            shift_reg <= 8'hFF;
            sda_out_reg <= 1;
          end
          bit_cnt <= 7;
        end
      endcase
    end
  end

endmodule
