`timescale 1ns / 1ps

module tb_ijtag_shared_aes;

    reg tck = 1'b0;
    reg clk = 1'b0;
    reg trst_n = 1'b0;
    reg reset_n = 1'b0;
    reg tms = 1'b1;
    reg tdi = 1'b0;
    reg decrypt_mode = 1'b0;

    wire tdo;
    wire aes_busy;
    wire aes_done;
    wire sib1_enable;
    wire sib2_enable;
    wire sib3_enable;
    wire select_ijtag;

    localparam [255:0] AES_KEY =
        256'h603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4;

    localparam [127:0] PLAINTEXT =
        128'h6bc1bee22e409f96e93d7e117393172a;

    localparam [127:0] EXPECTED =
        128'hf3eed1bdb5d2a03c064b5a7e3db181f8;

    reg [383:0] payload;
    reg [127:0] observed;

    integer i;
    integer failures = 0;
    integer sib;

    ijtag_aes_top dut (
        .tck          (tck),
        .clk          (clk),
        .trst_n       (trst_n),
        .reset_n      (reset_n),
        .tms          (tms),
        .tdi          (tdi),
        .decrypt_mode (decrypt_mode),
        .tdo          (tdo),
        .aes_busy     (aes_busy),
        .aes_done     (aes_done),
        .sib1_enable  (sib1_enable),
        .sib2_enable  (sib2_enable),
        .sib3_enable  (sib3_enable),
        .select_ijtag (select_ijtag)
    );

    always #5 tck = ~tck;
    always #5 clk = ~clk;

    // Drive TAP signals on falling edge; sample after rising edge.
    task tap_cycle;
        input tm;
        input td;
        begin
            @(negedge tck);
            tms = tm;
            tdi = td;
            @(posedge tck);
            #1;
        end
    endtask

    task load_instruction;
        input [3:0] instr;
        integer k;
        begin
            // Assumes TAP starts in Run-Test/Idle.
            tap_cycle(1'b1, 1'b0); // Select-DR
            tap_cycle(1'b1, 1'b0); // Select-IR
            tap_cycle(1'b0, 1'b0); // Capture-IR
            tap_cycle(1'b0, 1'b0); // Shift-IR

            for (k = 0; k < 4; k = k + 1)
                tap_cycle((k == 3), instr[k]);

            tap_cycle(1'b1, 1'b0); // Update-IR
            tap_cycle(1'b0, 1'b0); // Run-Test/Idle
        end
    endtask

    task write_config;
        input [2:0] desired;
        integer k;
        begin
            tap_cycle(1'b1, 1'b0); // Select-DR
            tap_cycle(1'b0, 1'b0); // Capture-DR
            tap_cycle(1'b0, 1'b0); // Shift-DR

            for (k = 0; k < 3; k = k + 1)
                tap_cycle((k == 2), desired[k]);

            tap_cycle(1'b1, 1'b0); // Update-DR
            tap_cycle(1'b0, 1'b0); // Run-Test/Idle
        end
    endtask

    task check_sib_selection;
        input [2:0] cfg;
        input [1:0] expected_sib;
        input expected_enable;
        begin
            load_instruction(4'b0011);
            write_config(cfg);
            load_instruction(4'b0010);
            #1;

            if ((dut.selected_sib !== expected_sib) ||
                (dut.instrument_enable !== expected_enable) ||
                (sib1_enable !== cfg[0]) ||
                (sib2_enable !== cfg[1]) ||
                (sib3_enable !== cfg[2])) begin
                $display(
                    "[FAIL] Config=%03b selected=%0d AES_enable=%b SIBs=%b%b%b",
                    cfg, dut.selected_sib, dut.instrument_enable,
                    sib3_enable, sib2_enable, sib1_enable
                );
                failures = failures + 1;
            end
            else begin
                $display(
                    "[PASS] Config=%03b SIBs=%b%b%b AES_enable=%b selected=%0d",
                    cfg, sib3_enable, sib2_enable, sib1_enable,
                    dut.instrument_enable, dut.selected_sib
                );
            end
        end
    endtask

    initial begin
        $display("==============================================");
        $display(" SHARED AES THROUGH IJTAG TEST");
        $display("==============================================");

        repeat (4) @(negedge tck);
        trst_n = 1'b1;
        reset_n = 1'b1;

        // Exit Test-Logic-Reset into Run-Test/Idle.
        tap_cycle(1'b0, 1'b0);
        tap_cycle(1'b0, 1'b0);

        // Verify all eight independent SIB open/bypass combinations.
        // Bit order is {SIB3,SIB2,SIB1}; 1=open, 0=bypass.
        // Any nonzero configuration can reach the one shared AES instrument.
        check_sib_selection(3'b000, 2'd0, 1'b0);
        check_sib_selection(3'b001, 2'd1, 1'b1);
        check_sib_selection(3'b010, 2'd2, 1'b1);
        check_sib_selection(3'b011, 2'd0, 1'b1);
        check_sib_selection(3'b100, 2'd3, 1'b1);
        check_sib_selection(3'b101, 2'd0, 1'b1);
        check_sib_selection(3'b110, 2'd0, 1'b1);
        check_sib_selection(3'b111, 2'd0, 1'b1);

        // Select SIB2 for the AES scan attempt.
        load_instruction(4'b0011);
        write_config(3'b010);
        load_instruction(4'b0010);

        if (dut.selected_sib !== 2'd2 ||
            dut.instrument_enable !== 1'b1) begin
            $display("[FAIL] Could not select shared AES through SIB2");
            failures = failures + 1;
            $finish;
        end

        // Payload order expected by the current wrapper:
        // key in the upper 256 bits, plaintext in lower 128 bits.
        payload = {AES_KEY, PLAINTEXT};

        $display("[INFO] Shifting 384-bit AES input payload");

        tap_cycle(1'b1, 1'b0); // Select-DR
        tap_cycle(1'b0, 1'b0); // Capture-DR
        tap_cycle(1'b0, 1'b0); // Shift-DR

        for (i = 0; i < 384; i = i + 1)
            tap_cycle((i == 383), payload[i]);

        tap_cycle(1'b1, 1'b0); // Update-DR
        tap_cycle(1'b0, 1'b0); // Run-Test/Idle

        $display("[INFO] Waiting for AES wrapper completion");

        // Timeout rather than hang indefinitely.
        fork
            begin
                wait (aes_done === 1'b1);
                $display("[INFO] aes_done asserted");
            end
            begin
                repeat (20000) @(posedge clk);
                if (aes_done !== 1'b1) begin
                    $display("[FAIL] Timeout waiting for aes_done");
                    failures = failures + 1;
                end
            end
        join_any
        disable fork;

        if (aes_done === 1'b1) begin
            $display("[INFO] AES wrapper completed.");

            // Capture the wrapper's result register, then shift 128 bits out.
            // TDO is sampled before each active TCK edge so we read the
            // current LSB before the scan register advances.
            $display("[INFO] Capturing AES result for scan-out");
            tap_cycle(1'b1, 1'b0); // Select-DR
            tap_cycle(1'b0, 1'b0); // Capture-DR
            tap_cycle(1'b0, 1'b0); // Shift-DR

            observed = 128'b0;
            for (i = 0; i < 128; i = i + 1) begin
                @(negedge tck);
                tms = (i == 127); // Exit Shift-DR after final result bit
                tdi = 1'b0;
                #1;
                observed[i] = tdo;
                @(posedge tck);
                #1;
            end

            tap_cycle(1'b1, 1'b0); // Update-DR
            tap_cycle(1'b0, 1'b0); // Run-Test/Idle

            $display("[INFO] Expected ciphertext: %032h", EXPECTED);
            $display("[INFO] Observed ciphertext: %032h", observed);
            if (observed === EXPECTED) begin
                $display("[PASS] AES-256 ciphertext matched through IJTAG scan-out");
            end else begin
                $display("[FAIL] AES-256 ciphertext mismatch through IJTAG scan-out");
                failures = failures + 1;
            end
        end

        $display("----------------------------------------------");
        if (failures == 0)
            $display("RESULT: ALL 8 SIB CONFIGURATIONS AND AES SCAN TESTS PASSED");
        else
            $display("RESULT: %0d TEST(S) FAILED", failures);
        $display("----------------------------------------------");

        $finish;
    end

endmodule
