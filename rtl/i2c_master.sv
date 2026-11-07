`timescale 1ns/1ps

module i2c_master #(
  parameter int CLK_DIV = 50 // SCL = clk / (4*CLK_DIV) approx
)(
  input  wire clk,
  input  wire rst_n,
  
  // Host Interface (Simple Req/Ack)
  input  wire       req_i,
  input  wire       rw_i, // 0=Write, 1=Read
  input  wire [6:0] addr_i,
  input  wire [7:0] data_in, // For Write
  output reg  [7:0] data_out, // For Read
  output reg        done_o,
  output reg        ack_error_o, // 1 if NACK received
  
  // I2C Interface
  input  wire scl_i,
  input  wire sda_i,
  output wire scl_o,
  output wire sda_o,
  output wire scl_oe,
  output wire sda_oe
);

  typedef enum logic [3:0] {
    IDLE,
    START,
    ADDR,
    ACK_ADDR,
    DATA_TX,
    ACK_DATA_TX,
    DATA_RX,
    ACK_DATA_RX,
    STOP
  } state_t;

  state_t state;
  
  // Registers
  logic [7:0] shift_reg;
  logic [2:0] bit_cnt;
  logic [15:0] clk_cnt;
  
  // Tri-state control
  logic scl_out_reg, sda_out_reg;
  
  // Open-drain: output follows internal reg, OE is inverted
  // When reg=0: OE=1, O=0 -> drives low
  // When reg=1: OE=0, O=1 -> high-Z (released)
  assign scl_o  = scl_out_reg;
  assign sda_o  = sda_out_reg;
  assign scl_oe = !scl_out_reg;
  assign sda_oe = !sda_out_reg;
  
  // Clock Generation (4 phases per SCL period)
  // 0: SCL Low (Change Data)
  // 1: SCL High (Stable Data)
  // 2: SCL High
  // 3: SCL Low
  
  logic scl_tick;
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
       clk_cnt <= 0;
       scl_tick <= 0;
    end else begin
       if (clk_cnt == CLK_DIV-1) begin
          clk_cnt <= 0;
          scl_tick <= 1;
       end else begin
          clk_cnt <= clk_cnt + 1;
          scl_tick <= 0;
       end
    end
  end

  // FSM driven by scl_tick
  // We need a sub-phase counter to manage SCL generation vs Data transitions
  // Let's use a simpler approach: State Machine handles sequence, separate SCL generator.
  // Actually for simplicity, let's just make a state machine that moves on ticks.
  
  // To keep it simple for this behavioral model:
  // We will assume "scl_tick" is 4x SCL frequency.
  
  logic [1:0] phase;
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      scl_out_reg <= 1;
      sda_out_reg <= 1;
      phase <= 0;
      done_o <= 0;
      ack_error_o <= 0;
    end else if (scl_tick) begin
       phase <= phase + 1;
       
       case (state)
         IDLE: begin
            scl_out_reg <= 1;
            sda_out_reg <= 1;
            done_o <= 0;
            if (req_i) begin
               state <= START;
               phase <= 0;
               shift_reg <= {addr_i, rw_i};
            end
         end
         
         START: begin
            // Generate Start: SDA High->Low while SCL High
            if (phase == 0) sda_out_reg <= 1; // SCL=1
            if (phase == 1) sda_out_reg <= 0; // SCL=1, SDA Fall
            if (phase == 2) scl_out_reg <= 0; // SCL Fall
            if (phase == 3) begin
               state <= ADDR;
               bit_cnt <= 7;
            end
         end
         
         ADDR: begin
            run_tx_byte(ACK_ADDR);
         end
         
         ACK_ADDR: begin
            if (shift_reg[0]) begin
               run_rx_ack(DATA_RX);
            end else begin
               run_rx_ack(DATA_TX);
               if (phase == 3) shift_reg <= data_in;
            end
         end
         
         DATA_TX: begin
            run_tx_byte(ACK_DATA_TX);
         end
         
         ACK_DATA_TX: begin
            run_rx_ack(STOP);
         end
         
         DATA_RX: begin
            run_rx_byte(ACK_DATA_RX);
         end
         
         ACK_DATA_RX: begin
            // Send NACK to end transfer (Simplified single byte read)
            run_tx_nack(STOP);
         end
         
         STOP: begin
            // Generate Stop: SDA Low->High while SCL High
            if (phase == 0) begin scl_out_reg <= 0; sda_out_reg <= 0; end
            if (phase == 1) begin scl_out_reg <= 1; end
            if (phase == 2) begin sda_out_reg <= 1; end // SDA Rise
            if (phase == 3) begin 
               state <= IDLE; 
               done_o <= 1;
            end
         end
         
       endcase
    end
  end
  
  // Helper tasks implemented as macros or inline logic due to Verilog limitations in always blocks
  // For clarity, we expand the logic here.
  
  task run_tx_byte(state_t next_s);
    if (phase == 0) begin scl_out_reg <= 0; sda_out_reg <= shift_reg[bit_cnt]; end
    if (phase == 1) begin scl_out_reg <= 1; end
    if (phase == 3) begin 
       scl_out_reg <= 0; 
       if (bit_cnt == 0) state <= next_s;
       else bit_cnt <= bit_cnt - 1;
    end
  endtask
  
  task run_rx_byte(state_t next_s);
    if (phase == 0) begin scl_out_reg <= 0; sda_out_reg <= 1; end // Release SDA
    if (phase == 1) begin scl_out_reg <= 1; end
    if (phase == 2) begin shift_reg[bit_cnt] <= sda_i; end // Sample
    if (phase == 3) begin
       scl_out_reg <= 0;
       if (bit_cnt == 0) begin 
          data_out <= shift_reg; // Store result
          state <= next_s;
          // bit_cnt will be reset by the caller/next state init
       end else begin
          bit_cnt <= bit_cnt - 1;
       end
    end
  endtask
  
  task run_rx_ack(state_t next_s);
    if (phase == 0) begin scl_out_reg <= 0; sda_out_reg <= 1; end // Release SDA
    if (phase == 1) begin scl_out_reg <= 1; end
    if (phase == 2) begin 
       if (sda_i) ack_error_o <= 1; // NACK received
    end 
    if (phase == 3) begin 
       scl_out_reg <= 0; 
       state <= next_s; 
       bit_cnt <= 7; // Reset bit counter for next byte (Data Phase)
    end
  endtask
  
  task run_tx_nack(state_t next_s);
    if (phase == 0) begin scl_out_reg <= 0; sda_out_reg <= 1; end // Send NACK (1)
    if (phase == 1) begin scl_out_reg <= 1; end
    if (phase == 3) begin scl_out_reg <= 0; state <= next_s; end
  endtask

endmodule
