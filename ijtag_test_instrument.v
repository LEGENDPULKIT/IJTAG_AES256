`timescale 1ns / 1ps

module ijtag_test_instrument (
    input wire tck,
    input wire trst_n,
    input wire capture_dr,
    input wire shift_dr,
    input wire select_instrument,
    input wire instrument_tdi,
    output wire instrument_tdo
);

    reg [7:0] scan_reg;

    assign instrument_tdo =
        select_instrument ? scan_reg[0] : 1'b0;

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)
            scan_reg <= 8'h00;
        else if (select_instrument && capture_dr)
            scan_reg <= 8'hA5;
        else if (select_instrument && shift_dr)
            scan_reg <= {instrument_tdi, scan_reg[7:1]};
    end

endmodule