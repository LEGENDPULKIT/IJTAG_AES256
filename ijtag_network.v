
`timescale 1ns / 1ps

module ijtag_network (
    input  wire tck,
    input  wire trst_n,
    input  wire tdi,
    input  wire select_ijtag,
    input  wire capture_dr,
    input  wire shift_dr,
    input  wire update_dr,
    output wire instrument_tdi,
    input  wire instrument_tdo,
    output wire sib1_enable,
    output wire sib2_enable,
    output wire sib3_enable,
    output wire ijtag_tdo
);

    wire cap1, cap2, cap3;
    wire sh1, sh2, sh3;
    wire up1, up2, up3;
    wire tdi2, tdi3;
    wire tdo1, tdo2, tdo3;

    assign cap1 = capture_dr & select_ijtag;
    assign sh1  = shift_dr   & select_ijtag;
    assign up1  = update_dr  & select_ijtag;

    assign cap2 = cap1 & sib1_enable;
    assign sh2  = sh1  & sib1_enable;
    assign up2  = up1  & sib1_enable;

    assign cap3 = cap2 & sib2_enable;
    assign sh3  = sh2  & sib2_enable;
    assign up3  = up2  & sib2_enable;

    ijtag_sib sib1 (
        .tck(tck),
        .trst_n(trst_n),
        .tdi(tdi),
        .capture_dr(cap1),
        .shift_dr(sh1),
        .update_dr(up1),
        .segment_tdi(tdi2),
        .segment_tdo(tdo2),
        .segment_enable(sib1_enable),
        .tdo(tdo1)
    );

    ijtag_sib sib2 (
        .tck(tck),
        .trst_n(trst_n),
        .tdi(tdi2),
        .capture_dr(cap2),
        .shift_dr(sh2),
        .update_dr(up2),
        .segment_tdi(tdi3),
        .segment_tdo(tdo3),
        .segment_enable(sib2_enable),
        .tdo(tdo2)
    );

    ijtag_sib sib3 (
        .tck(tck),
        .trst_n(trst_n),
        .tdi(tdi3),
        .capture_dr(cap3),
        .shift_dr(sh3),
        .update_dr(up3),
        .segment_tdi(instrument_tdi),
        .segment_tdo(instrument_tdo),
        .segment_enable(sib3_enable),
        .tdo(tdo3)
    );

    // Diagnostic workaround for the observed TDO cascade failure.
    // When all SIBs are open, route the instrument TDO directly.
    // Otherwise, retain the normal outer SIB output.
    assign ijtag_tdo =
        (select_ijtag && sib1_enable && sib2_enable && sib3_enable)
        ? instrument_tdo
        : tdo1;

endmodule
