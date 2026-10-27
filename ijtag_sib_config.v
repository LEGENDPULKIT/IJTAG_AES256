
`timescale 1ns / 1ps

module ijtag_sib_config (
    input  wire       tck,
    input  wire       trst_n,
    input  wire       tdi,
    input  wire       capture_dr,
    input  wire       shift_dr,
    input  wire       update_dr,
    input  wire       config_mode,
    output wire       tdo,
    output wire [2:0] sib_enable
);

    reg [2:0] shift_reg;
    reg [2:0] active_reg;

    assign sib_enable = active_reg;

    // Serial output is the current least-significant shift bit.
    assign tdo = (config_mode && shift_dr) ? shift_reg[0] : 1'b0;

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            shift_reg <= 3'b000;
            active_reg <= 3'b000;
        end
        else if (config_mode) begin
            if (capture_dr)
                shift_reg <= active_reg;
            else if (shift_dr)
                shift_reg <= {tdi, shift_reg[2:1]};

            if (update_dr)
                active_reg <= shift_reg;
        end
    end

endmodule
