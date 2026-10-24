
`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// Top-level: JTAG + 3-SIB IJTAG + temporary 8-bit test instrument
//
// Phase 1:
//   - JTAG TAP instruction selection
//   - Hierarchical 3-SIB IJTAG control
//   - Temporary scan instrument for scan-path verification
//
// AES-256 will be reconnected in Phase 2.
// -----------------------------------------------------------------------------

module ijtag_aes_top (
    input  wire tck,
    input  wire trst_n,
    input  wire tms,
    input  wire tdi,
    output wire tdo,

    // Debug/status outputs retained for testbench compatibility.
    output wire aes_busy,
    output wire aes_done,
    output wire sib1_enable,
    output wire sib2_enable,
    output wire sib3_enable,
    output wire select_ijtag
);

    // -------------------------------------------------------------------------
    // JTAG instruction and control signals
    // -------------------------------------------------------------------------

    wire [3:0] instruction;

    wire select_idcode;
    wire select_bypass;

    wire capture_dr;
    wire shift_dr;
    wire update_dr;

    // -------------------------------------------------------------------------
    // IJTAG and instrument connections
    // -------------------------------------------------------------------------

    wire ijtag_tdo;
    wire instrument_tdi;
    wire instrument_tdo;

    wire select_instrument;

    // Instrument is selected only when all three SIBs are open.
    assign select_instrument =
           sib1_enable &&
           sib2_enable &&
           sib3_enable;

    // AES is intentionally disconnected in Phase 1.
    assign aes_busy = 1'b0;
    assign aes_done = 1'b0;

    // -------------------------------------------------------------------------
    // JTAG TAP
    // Owns TAP FSM, IR, instruction decoding, and final TDO.
    // -------------------------------------------------------------------------

    jtag_tap u_jtag_tap (
        .tck           (tck),
        .trst_n        (trst_n),
        .tms           (tms),
        .tdi           (tdi),
        .tdo           (tdo),
        .instruction   (instruction),
        .select_idcode (select_idcode),
        .select_ijtag  (select_ijtag),
        .select_bypass (select_bypass),
        .capture_dr    (capture_dr),
        .shift_dr      (shift_dr),
        .update_dr     (update_dr),
        .ijtag_tdo     (ijtag_tdo)
    );

    // -------------------------------------------------------------------------
    // Three-SIB IJTAG network
    // -------------------------------------------------------------------------

    ijtag_network u_ijtag_network (
        .tck            (tck),
        .trst_n         (trst_n),
        .tdi            (tdi),
        .select_ijtag   (select_ijtag),
        .capture_dr     (capture_dr),
        .shift_dr       (shift_dr),
        .update_dr      (update_dr),
        .instrument_tdi (instrument_tdi),
        .instrument_tdo (instrument_tdo),
        .sib1_enable    (sib1_enable),
        .sib2_enable    (sib2_enable),
        .sib3_enable    (sib3_enable),
        .ijtag_tdo      (ijtag_tdo)
    );

    // -------------------------------------------------------------------------
    // Temporary 8-bit scan instrument
    // Replaces aes_ijtag_wrapper during Phase 1 testing.
    // -------------------------------------------------------------------------

    ijtag_test_instrument u_test_instrument (
        .tck               (tck),
        .trst_n            (trst_n),
        .capture_dr        (capture_dr && select_ijtag &&
                            select_instrument),
        .shift_dr          (shift_dr && select_ijtag &&
                            select_instrument),
        .select_instrument (select_instrument),
        .instrument_tdi    (instrument_tdi),
        .instrument_tdo    (instrument_tdo)
    );


endmodule
