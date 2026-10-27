`timescale 1ns / 1ps
// Shared-AES access selector prototype.
// Configuration is one-hot: 001 selects SIB1, 010 selects SIB2,
// 100 selects SIB3. 000 and multi-hot values fail safe to bypass.
// Because the AES instrument is shared, this is a muxed access topology,
// not three copies of AES and not a claim of IEEE 1687 compliance.
module ijtag_network (
    input  wire       tck,
    input  wire       trst_n,
    input  wire       tdi,
    input  wire       select_ijtag,
    input  wire       capture_dr,
    input  wire       shift_dr,
    input  wire       update_dr,
    input  wire       sib1_config_enable,
    input  wire       sib2_config_enable,
    input  wire       sib3_config_enable,
    output wire       instrument_tdi,
    input  wire       instrument_tdo,
    output wire       sib1_enable,
    output wire       sib2_enable,
    output wire       sib3_enable,
    output wire       instrument_enable,
    output wire [1:0] selected_sib,
    output wire       ijtag_tdo
);
    wire scan_capture = capture_dr & select_ijtag;
    wire scan_shift   = shift_dr & select_ijtag;
    wire [2:0] cfg = {sib3_config_enable, sib2_config_enable, sib1_config_enable};
    reg [2:0] bypass_shift;
    wire one_hot = (cfg == 3'b001) || (cfg == 3'b010) || (cfg == 3'b100);

    assign instrument_enable = one_hot;
    assign selected_sib = (cfg == 3'b001) ? 2'd1 :
                          (cfg == 3'b010) ? 2'd2 :
                          (cfg == 3'b100) ? 2'd3 : 2'd0;
    assign sib1_enable = (cfg == 3'b001);
    assign sib2_enable = (cfg == 3'b010);
    assign sib3_enable = (cfg == 3'b100);

    // In this shared-instrument topology, the selected SIB aliases the one
    // AES instrument directly. Invalid/zero-hot configuration uses a 3-bit
    // serial bypass chain so the network remains scannable without AES access.
    assign instrument_tdi = instrument_enable ? tdi : 1'b0;
    assign ijtag_tdo = instrument_enable ? instrument_tdo : bypass_shift[0];

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            bypass_shift <= 3'b000;
        end else if (scan_capture) begin
            bypass_shift <= 3'b000;
        end else if (scan_shift && !instrument_enable) begin
            bypass_shift <= {tdi, bypass_shift[2:1]};
        end
    end
endmodule
