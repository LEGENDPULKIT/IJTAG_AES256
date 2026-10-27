`timescale 1ns / 1ps
// Shared-AES IJTAG network supporting all eight 3-bit SIB configurations.
// Each configuration bit independently marks its SIB as open (1) or
// bypassed (0). Since this prototype has ONE shared AES instrument, any
// nonzero configuration grants access to that instrument. 000 leaves AES
// disconnected and uses the serial bypass register. This is a muxed prototype,
// not a claim of full IEEE 1687 SIB-chain compliance.
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
    wire any_sib_open = |cfg;
    wire one_hot = (cfg == 3'b001) || (cfg == 3'b010) || (cfg == 3'b100);

    // Preserve each SIB's independently programmed open/bypass state.
    assign sib1_enable = sib1_config_enable;
    assign sib2_enable = sib2_config_enable;
    assign sib3_enable = sib3_config_enable;

    // The shared AES is reachable whenever at least one SIB path is open.
    // Multiple open SIBs are allowed and still refer to the same AES instance.
    assign instrument_enable = any_sib_open;

    // selected_sib is meaningful only for one-hot configurations. For multi-hot
    // settings it is 0, while instrument_enable remains asserted.
    assign selected_sib = (cfg == 3'b001) ? 2'd1 :
                          (cfg == 3'b010) ? 2'd2 :
                          (cfg == 3'b100) ? 2'd3 : 2'd0;

    assign instrument_tdi = instrument_enable ? tdi : 1'b0;
    assign ijtag_tdo = instrument_enable ? instrument_tdo : bypass_shift[0];

    // When every SIB is closed, keep a 3-bit bypass path available.
    // For any nonzero config, scan data is routed to/from the shared AES.
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)
            bypass_shift <= 3'b000;
        else if (scan_capture)
            bypass_shift <= 3'b000;
        else if (scan_shift && !any_sib_open)
            bypass_shift <= {tdi, bypass_shift[2:1]};
    end
endmodule
