
`timescale 1ns / 1ps

module ijtag_aes_top (
    input  wire tck,
    input  wire clk,
    input  wire trst_n,
    input  wire reset_n,
    input  wire tms,
    input  wire tdi,
    input  wire decrypt_mode,

    output wire tdo,
    output wire aes_busy,
    output wire aes_done,

    output wire sib1_enable,
    output wire sib2_enable,
    output wire sib3_enable,
    output wire select_ijtag
);

    wire [3:0] instruction;

    wire select_idcode;
    wire select_bypass;
    wire select_sib_config;

    wire capture_dr;
    wire shift_dr;
    wire update_dr;

    wire tap_tdo;
    wire ijtag_tdo;
    wire config_tdo;

    wire instrument_tdi;
    wire instrument_tdo;
    wire instrument_enable;

    wire [1:0] selected_sib;
    wire [2:0] sib_enable_config;

    jtag_tap u_jtag_tap (
        .tck               (tck),
        .trst_n            (trst_n),
        .tms               (tms),
        .tdi               (tdi),
        .tdo               (tap_tdo),

        .instruction       (instruction),
        .select_idcode     (select_idcode),
        .select_ijtag      (select_ijtag),
        .select_bypass     (select_bypass),
        .select_sib_config (select_sib_config),

        .capture_dr        (capture_dr),
        .shift_dr          (shift_dr),
        .update_dr         (update_dr),

        .ijtag_tdo         (ijtag_tdo),
        .config_tdo        (config_tdo)
    );

    assign tdo = tap_tdo;

    // TAP instruction 0011 accesses the configuration register.
    ijtag_sib_config u_sib_config (
        .tck         (tck),
        .trst_n      (trst_n),
        .tdi         (tdi),

        .capture_dr  (capture_dr && select_sib_config),
        .shift_dr    (shift_dr   && select_sib_config),
        .update_dr   (update_dr  && select_sib_config),

        .config_mode (select_sib_config),
        .tdo         (config_tdo),
        .sib_enable  (sib_enable_config)
    );

    // Expose programmed configuration for simulation/debug.
    assign sib1_enable = sib_enable_config[0];
    assign sib2_enable = sib_enable_config[1];
    assign sib3_enable = sib_enable_config[2];

    // Shared-AES scan access selector.
    ijtag_network u_ijtag_network (
        .tck                 (tck),
        .trst_n              (trst_n),
        .tdi                 (tdi),

        .select_ijtag        (select_ijtag),
        .capture_dr          (capture_dr),
        .shift_dr            (shift_dr),
        .update_dr           (update_dr),

        .sib1_config_enable  (sib_enable_config[0]),
        .sib2_config_enable  (sib_enable_config[1]),
        .sib3_config_enable  (sib_enable_config[2]),

        .instrument_tdi      (instrument_tdi),
        .instrument_tdo      (instrument_tdo),

        .sib1_enable         (),
        .sib2_enable         (),
        .sib3_enable         (),

        .instrument_enable   (instrument_enable),
        .selected_sib        (selected_sib),
        .ijtag_tdo           (ijtag_tdo)
    );

    // One shared AES instrument. Its core RTL is unchanged.
    aes_ijtag_wrapper u_shared_aes_instrument (
        .clk          (clk),
        .reset_n      (reset_n),

        .instrument_tdi (instrument_tdi),
        .instrument_tdo (instrument_tdo),

        .capture_dr   (capture_dr &&
                       select_ijtag &&
                       instrument_enable),

        .shift_dr     (shift_dr &&
                       select_ijtag &&
                       instrument_enable),

        .aes_busy     (aes_busy),
        .aes_done     (aes_done)
    );

    // The current AES wrapper supports encryption only.
    // Keep decrypt_mode for compatibility with the existing top-level port.
    wire unused_decrypt_mode = decrypt_mode;

endmodule
