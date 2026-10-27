
`timescale 1ns / 1ps

module jtag_tap #(
    // Placeholder for simulation only.
    // Replace with the IDCODE assigned for your target device.
    parameter [31:0] IDCODE_VALUE = 32'h00000001
)(
    input  wire        tck,
    input  wire        trst_n,
    input  wire        tms,
    input  wire        tdi,

    output reg         tdo,
    output wire [3:0]  instruction,

    output wire        select_idcode,
    output wire        select_ijtag,
    output wire        select_bypass,
    output wire        select_sib_config,

    output wire        capture_dr,
    output wire        shift_dr,
    output wire        update_dr,

    input  wire        ijtag_tdo,
    input  wire        config_tdo
);

// --------------------------------------------------
// TAP STATES
// --------------------------------------------------
localparam TEST_LOGIC_RESET = 4'd0;
localparam RUN_TEST_IDLE    = 4'd1;
localparam SELECT_DR_SCAN   = 4'd2;
localparam CAPTURE_DR       = 4'd3;
localparam SHIFT_DR         = 4'd4;
localparam EXIT1_DR         = 4'd5;
localparam PAUSE_DR         = 4'd6;
localparam EXIT2_DR         = 4'd7;
localparam UPDATE_DR        = 4'd8;

localparam SELECT_IR_SCAN   = 4'd9;
localparam CAPTURE_IR       = 4'd10;
localparam SHIFT_IR         = 4'd11;
localparam EXIT1_IR         = 4'd12;
localparam PAUSE_IR         = 4'd13;
localparam EXIT2_IR         = 4'd14;
localparam UPDATE_IR        = 4'd15;

// --------------------------------------------------
// INSTRUCTIONS
// --------------------------------------------------
localparam IDCODE_INSTR = 4'b0001;
localparam IJTAG_INSTR  = 4'b0010;
localparam BYPASS_INSTR = 4'b1111;
localparam SIB_CONFIG_INSTR = 4'b0011;

// --------------------------------------------------
// REGISTERS
// --------------------------------------------------
reg [3:0] state;
reg [3:0] next_state;

reg [3:0] ir_shift;
reg [3:0] ir_reg;

// Generic DR retained for the existing prototype.
reg [7:0] dr_shift;
reg [7:0] dr_reg;

// Dedicated IDCODE and BYPASS registers.
reg [31:0] idcode_shift;
reg        bypass_shift;

// --------------------------------------------------
// INSTRUCTION DECODE AND CONTROL OUTPUTS
// --------------------------------------------------
assign instruction   = ir_reg;

assign select_idcode = (ir_reg == IDCODE_INSTR);
assign select_ijtag  = (ir_reg == IJTAG_INSTR);
assign select_bypass = (ir_reg == BYPASS_INSTR);
assign select_sib_config = (ir_reg == SIB_CONFIG_INSTR);

assign capture_dr = (state == CAPTURE_DR);
assign shift_dr   = (state == SHIFT_DR);
assign update_dr  = (state == UPDATE_DR);

// --------------------------------------------------
// TAP STATE REGISTER
// --------------------------------------------------
always @(posedge tck or negedge trst_n) begin
    if (!trst_n)
        state <= TEST_LOGIC_RESET;
    else
        state <= next_state;
end

// --------------------------------------------------
// TAP STATE TRANSITIONS
// --------------------------------------------------
always @(*) begin
    next_state = TEST_LOGIC_RESET;

    case (state)
        TEST_LOGIC_RESET:
            next_state = tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE;

        RUN_TEST_IDLE:
            next_state = tms ? SELECT_DR_SCAN : RUN_TEST_IDLE;

        SELECT_DR_SCAN:
            next_state = tms ? SELECT_IR_SCAN : CAPTURE_DR;

        CAPTURE_DR:
            next_state = tms ? EXIT1_DR : SHIFT_DR;

        SHIFT_DR:
            next_state = tms ? EXIT1_DR : SHIFT_DR;

        EXIT1_DR:
            next_state = tms ? UPDATE_DR : PAUSE_DR;

        PAUSE_DR:
            next_state = tms ? EXIT2_DR : PAUSE_DR;

        EXIT2_DR:
            next_state = tms ? UPDATE_DR : SHIFT_DR;

        UPDATE_DR:
            next_state = tms ? SELECT_DR_SCAN : RUN_TEST_IDLE;

        SELECT_IR_SCAN:
            next_state = tms ? TEST_LOGIC_RESET : CAPTURE_IR;

        CAPTURE_IR:
            next_state = tms ? EXIT1_IR : SHIFT_IR;

        SHIFT_IR:
            next_state = tms ? EXIT1_IR : SHIFT_IR;

        EXIT1_IR:
            next_state = tms ? UPDATE_IR : PAUSE_IR;

        PAUSE_IR:
            next_state = tms ? EXIT2_IR : PAUSE_IR;

        EXIT2_IR:
            next_state = tms ? UPDATE_IR : SHIFT_IR;

        UPDATE_IR:
            next_state = tms ? SELECT_DR_SCAN : RUN_TEST_IDLE;

        default:
            next_state = TEST_LOGIC_RESET;
    endcase
end

// --------------------------------------------------
// INSTRUCTION REGISTER
// --------------------------------------------------
always @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
        ir_shift <= 4'b0000;
        // IDCODE is selected after reset because this
        // prototype implements an IDCODE register.
        ir_reg <= IDCODE_INSTR;
    end else begin
        if (state == CAPTURE_IR)
            ir_shift <= 4'b0001;
        else if (state == SHIFT_IR)
            ir_shift <= {tdi, ir_shift[3:1]};

        if (state == UPDATE_IR)
            ir_reg <= ir_shift;
    end
end

// --------------------------------------------------
// DATA REGISTERS
// --------------------------------------------------
always @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
        dr_shift     <= 8'b0;
        dr_reg       <= 8'b0;
        idcode_shift <= IDCODE_VALUE;
        bypass_shift <= 1'b0;
    end else begin

        // IDCODE: capture the 32-bit identification value.
        if (state == CAPTURE_DR && select_idcode)
            idcode_shift <= IDCODE_VALUE;
        else if (state == SHIFT_DR && select_idcode)
            idcode_shift <= {tdi, idcode_shift[31:1]};

        // BYPASS: one-bit data register.
        if (state == CAPTURE_DR && select_bypass)
            bypass_shift <= 1'b0;
        else if (state == SHIFT_DR && select_bypass)
            bypass_shift <= tdi;

        // Existing generic data register, retained for
        // compatibility with the current prototype.
        if (state == CAPTURE_DR)
            dr_shift <= 8'b10101010;
        else if (state == SHIFT_DR &&
                 !select_idcode &&
                 !select_bypass &&
                 !select_ijtag &&
                 !select_sib_config)
            dr_shift <= {tdi, dr_shift[7:1]};

        if (state == UPDATE_DR)
            dr_reg <= dr_shift;
    end
end

// --------------------------------------------------
// TDO SELECTION
// --------------------------------------------------
always @(*) begin
    tdo = 1'b0;

    if (state == SHIFT_IR)
        tdo = ir_shift[0];

    else if (state == SHIFT_DR) begin
        if (select_sib_config)
            tdo = config_tdo;
        else if (select_ijtag)
            tdo = ijtag_tdo;
        else if (select_idcode)
            tdo = idcode_shift[0];
        else if (select_bypass)
            tdo = bypass_shift;
        else
            tdo = dr_shift[0];
    end
end

endmodule
