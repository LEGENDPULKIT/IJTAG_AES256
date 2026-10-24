
`timescale 1ns / 1ps

module ijtag_aes_top (
    input  wire tck,
    input  wire clk,
    input  wire trst_n,
    input  wire reset_n,
    input  wire tms,
    input  wire tdi,
    input  wire decrypt_mode, // 0 = encrypt, 1 = decrypt
    output wire tdo,

    output wire aes_busy,
    output wire aes_done,

    output wire sib1_enable,
    output wire sib2_enable,
    output wire sib3_enable,

    output wire select_ijtag
);

    // --------------------------------------------------
    // JTAG TAP signals
    // --------------------------------------------------
    wire [3:0] instruction;

    wire select_idcode;
    wire select_bypass;

    wire capture_dr;
    wire shift_dr;
    wire update_dr;

    wire tap_tdo;

    // --------------------------------------------------
    // IJTAG network signals
    // --------------------------------------------------
    wire instrument_tdi;
    wire instrument_tdo;
    wire ijtag_tdo;

    // --------------------------------------------------
    // JTAG TAP controller
    // Ports match the supplied jtag_tap module.
    // --------------------------------------------------
    jtag_tap u_jtag_tap (
        .tck           (tck),
        .trst_n        (trst_n),
        .tms           (tms),
        .tdi           (tdi),
        .tdo           (tap_tdo),
        .instruction   (instruction),

        .select_idcode (select_idcode),
        .select_ijtag  (select_ijtag),
        .select_bypass (select_bypass),

        .capture_dr    (capture_dr),
        .shift_dr      (shift_dr),
        .update_dr     (update_dr),

        .ijtag_tdo     (ijtag_tdo)
    );

    // --------------------------------------------------
    // IJTAG network
    // --------------------------------------------------
    ijtag_network u_ijtag_network (
        .tck             (tck),
        .trst_n          (trst_n),
        .tdi             (tdi),
        .select_ijtag    (select_ijtag),
        .capture_dr      (capture_dr),
        .shift_dr        (shift_dr),
        .update_dr       (update_dr),

        .instrument_tdi  (instrument_tdi),
        .instrument_tdo  (instrument_tdo),

        .sib1_enable     (sib1_enable),
        .sib2_enable     (sib2_enable),
        .sib3_enable     (sib3_enable),

        .ijtag_tdo       (ijtag_tdo)
    );

    // --------------------------------------------------
    // AES-256 instrument wrapper
    // --------------------------------------------------

  
aes_ijtag_wrapper u_aes_ijtag_wrapper (
    .clk             (clk),
    .reset_n         (reset_n),

    .instrument_tdi  (instrument_tdi),
    .instrument_tdo  (instrument_tdo),

    .capture_dr      (capture_dr && select_ijtag),
    .shift_dr        (shift_dr && select_ijtag),
    .decrypt_mode    (decrypt_mode),

    .aes_busy        (aes_busy),
    .aes_done        (aes_done)
);



    // --------------------------------------------------
    // Top-level TDO
    // The TAP selects ijtag_tdo when IJTAG is active.
    // --------------------------------------------------
    assign tdo = tap_tdo;

endmodule
