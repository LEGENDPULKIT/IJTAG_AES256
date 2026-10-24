
`timescale 1ns / 1ps

module ijtag_sib (
    input  wire tck,
    input  wire trst_n,
    input  wire tdi,
    input  wire capture_dr,
    input  wire shift_dr,
    input  wire update_dr,
    output wire segment_tdi,
    input  wire segment_tdo,
    output wire segment_enable,
    output wire tdo
);

    reg sib_shift;
    reg sib_active;

    // SIB active state controls whether its downstream segment is open.
    assign segment_enable = sib_active;

    // Forward scan input into the downstream segment.
    assign segment_tdi = tdi;

    // When open, TDO comes from the downstream segment.
    // When closed, TDO is the SIB's own control bit.
    assign tdo = sib_active ? segment_tdo : sib_shift;

    // Capture, shift, and update operations.
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            sib_shift  <= 1'b0;
            sib_active <= 1'b0;
        end
        else begin
            if (capture_dr) begin
                sib_shift <= sib_active;
            end
            else if (shift_dr) begin
                if (sib_active)
                    sib_shift <= segment_tdo;
                else
                    sib_shift <= tdi;
            end

            if (update_dr)
                sib_active <= sib_shift;
        end
    end

endmodule
