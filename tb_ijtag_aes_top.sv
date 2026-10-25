`timescale 1ns / 1ps

// Layered plain-SystemVerilog testbench for IJTAG + AES-256.
// Tests encryption first, then decryption after a DUT reset.
// Assumes the top module is ijtag_aes_top and has decrypt_mode input.
// Assumes the wrapper's scan payload is {256-bit key, 128-bit input block}.

module tb_ijtag_aes_top;

    reg clk, tck, trst_n, reset_n, tms, tdi;
    reg decrypt_mode;

    wire tdo, aes_busy, aes_done;
    wire sib1_enable, sib2_enable, sib3_enable;
    wire select_ijtag;

    integer errors, checks, timeout_count;
    integer bit_index;
    reg [383:0] payload;
    reg [127:0] ciphertext;
    reg [127:0] recovered_plaintext;
    reg [127:0] expected_ciphertext;
    reg [127:0] expected_plaintext;

    localparam [3:0] IJTAG_INSTR = 4'b0010;
    localparam [3:0] TAP_SHIFT_DR = 4'd4;
    localparam integer AES_TIMEOUT_CYCLES = 2000;

    ijtag_aes_top dut (
        .tck(tck),
        .clk(clk),
        .trst_n(trst_n),
        .reset_n(reset_n),
        .tms(tms),
        .tdi(tdi),
        .decrypt_mode(decrypt_mode),
        .tdo(tdo),
        .aes_busy(aes_busy),
        .aes_done(aes_done),
        .sib1_enable(sib1_enable),
        .sib2_enable(sib2_enable),
        .sib3_enable(sib3_enable),
        .select_ijtag(select_ijtag)
    );

    initial begin
        clk = 1'b0;
        tck = 1'b0;
    end

    // Keep the clocks in phase, matching the original testbench.
    always #5 begin
        clk = ~clk;
        tck = ~tck;
    end

    task automatic check(
        input reg condition,
        input [255:0] label_text
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("[FAIL] %0s at %0t", label_text, $time);
            end
            else begin
                $display("[PASS] %0s", label_text);
            end
        end
    endtask

    task automatic drive_cycle(input reg tm, input reg ti);
        begin
            @(negedge tck);
            tms = tm;
            tdi = ti;
            @(posedge tck);
            #1;
        end
    endtask

    task automatic reset_environment;
        begin
            @(negedge tck);
            trst_n = 1'b0;
            reset_n = 1'b0;
            tms = 1'b1;
            tdi = 1'b0;

            repeat (4) @(posedge tck);
            #1;

            check(
                {sib1_enable,sib2_enable,sib3_enable} === 3'b000,
                "Reset closes all SIBs"
            );

            @(negedge tck);
            trst_n = 1'b1;
            reset_n = 1'b1;
            drive_cycle(1'b0, 1'b0);
        end
    endtask

    task automatic load_instruction(input [3:0] instr);
        integer b;
        begin
            drive_cycle(1,0); // Select-DR
            drive_cycle(1,0); // Select-IR
            drive_cycle(0,0); // Capture-IR
            drive_cycle(0,0); // Shift-IR

            for (b = 0; b < 4; b = b + 1)
                drive_cycle((b == 3), instr[b]);

            drive_cycle(1,0); // Update-IR
            drive_cycle(0,0); // Run-Test/Idle

            check(
                dut.u_jtag_tap.instruction === instr,
                "TAP instruction loaded"
            );
        end
    endtask

    task automatic enter_shift_dr;
        begin
            repeat (5) drive_cycle(1'b1, 1'b0);
            drive_cycle(1'b0, 1'b0); // Run-Test/Idle
            drive_cycle(1'b1, 1'b0); // Select-DR
            drive_cycle(1'b0, 1'b0); // Capture-DR
            drive_cycle(1'b0, 1'b0); // Shift-DR

            if (dut.u_jtag_tap.state !== TAP_SHIFT_DR)
                $fatal(1, "[SEQUENCE] TAP failed to enter Shift-DR");
        end
    endtask

    task automatic exit_update_dr;
        begin
            drive_cycle(1'b1, 1'b0); // Exit1-DR
            drive_cycle(1'b1, 1'b0); // Update-DR
            drive_cycle(1'b0, 1'b0); // Run-Test/Idle
        end
    endtask

    task automatic open_all_sibs;
        begin
            if (sib1_enable !== 1'b1) begin
                $display("[SEQUENCE] Opening SIB1...");
                enter_shift_dr();
                drive_cycle(1'b1, 1'b1);
                exit_update_dr();
            end

            if (sib1_enable !== 1'b1)
                $fatal(1, "[SEQUENCE] SIB1 failed to open");

            if (sib2_enable !== 1'b1) begin
                $display("[SEQUENCE] Opening SIB2...");
                enter_shift_dr();
                drive_cycle(1'b0, 1'b1);
                drive_cycle(1'b1, 1'b1);
                exit_update_dr();
            end

            if ({sib1_enable,sib2_enable} !== 2'b11)
                $fatal(1, "[SEQUENCE] SIB2 failed to open");

            if (sib3_enable !== 1'b1) begin
                $display("[SEQUENCE] Opening SIB3...");
                enter_shift_dr();
                drive_cycle(1'b0, 1'b1);
                drive_cycle(1'b0, 1'b1);
                drive_cycle(1'b1, 1'b1);
                exit_update_dr();
            end

            check(
                {sib1_enable,sib2_enable,sib3_enable} === 3'b111,
                "All three SIBs open"
            );
        end
    endtask

    // Check that a closed SIB3 keeps the AES instrument out of the scan path.
    task automatic test_sib3_bypass;
        integer b;
        begin
            $display("\n[TEST 0] CLOSED SIB3 BYPASS / AES ISOLATION");

            reset_environment();
            load_instruction(IJTAG_INSTR);

            // Open SIB1 and SIB2, leaving SIB3 (the AES instrument segment) closed.
            enter_shift_dr();
            drive_cycle(1'b1, 1'b1);
            exit_update_dr();

            enter_shift_dr();
            drive_cycle(1'b0, 1'b1);
            drive_cycle(1'b1, 1'b1);
            exit_update_dr();

            check(
                {sib1_enable,sib2_enable,sib3_enable} === 3'b110,
                "SIB3 stays closed for bypass test"
            );

            enter_shift_dr();

            // A closed SIB should return its own shifted control bit on TDO.
            drive_cycle(1'b0, 1'b1);
            check(tdo === 1'b1, "Closed SIB3 returns its shifted bit");

            // Continue shifting while SIB3 is closed. The AES wrapper should
            // remain isolated, so its scan counter should stay at zero.
            for (b = 1; b < 8; b = b + 1)
                drive_cycle(1'b0, 1'b0);

            check(
                dut.u_aes_ijtag_wrapper.shift_count === 9'd0,
                "Closed SIB blocks AES scan"
            );
            check(aes_busy === 1'b0, "AES remains idle during SIB bypass");

            // Reset leaves the normal AES tests with a clean starting state.
            reset_environment();
        end
    endtask

    task automatic load_aes_payload(input [383:0] data);
        integer b;
        begin
            $display("[SEQUENCE] Shifting 384-bit payload...");
            enter_shift_dr();

            for (b = 0; b < 384; b = b + 1) begin
                @(negedge tck);
                tms = (b == 383);
                tdi = data[b];
                @(posedge tck);
                #1;
            end

            drive_cycle(1'b1, 1'b0); // Exit1-DR -> Update-DR
            drive_cycle(1'b0, 1'b0); // Update-DR -> Run-Test/Idle
        end
    endtask

    task automatic enter_shift_dr_safely;
        begin
            case (dut.u_jtag_tap.state)
                4'd4: begin end // Already Shift-DR
                4'd3: drive_cycle(1'b0, 1'b0); // Capture-DR -> Shift-DR
                4'd6: begin
                    drive_cycle(1'b1, 1'b0); // Pause-DR -> Exit2-DR
                    drive_cycle(1'b0, 1'b0); // Exit2-DR -> Shift-DR
                end
                4'd7: drive_cycle(1'b0, 1'b0); // Exit2-DR -> Shift-DR
                4'd1: begin
                    drive_cycle(1'b1, 1'b0); // Idle -> Select-DR
                    drive_cycle(1'b0, 1'b0); // Select-DR -> Capture-DR
                    drive_cycle(1'b0, 1'b0); // Capture-DR -> Shift-DR
                end
                4'd2: begin
                    drive_cycle(1'b0, 1'b0); // Select-DR -> Capture-DR
                    drive_cycle(1'b0, 1'b0); // Capture-DR -> Shift-DR
                end
                default: begin
                    $display("[SEQUENCE] Unsupported TAP state=%0d",
                             dut.u_jtag_tap.state);
                    $fatal(1, "[SEQUENCE] Cannot safely enter Shift-DR");
                end
            endcase

            #1;
            if (dut.u_jtag_tap.state !== TAP_SHIFT_DR)
                $fatal(1, "[SEQUENCE] TAP did not reach Shift-DR");

            if ({sib1_enable,sib2_enable,sib3_enable} !== 3'b111)
                $fatal(1, "[SEQUENCE] SIB path is not fully open");
        end
    endtask

    task automatic report_aes_status;
        begin
            $display("[MONITOR] busy=%b done=%b wrapper_state=%0d mode=%b",
                     aes_busy, aes_done, dut.u_aes_ijtag_wrapper.state,
                     decrypt_mode);
        end
    endtask

    task automatic wait_for_aes;
        begin
            timeout_count = 0;
            $display("[SEQUENCE] Waiting for AES completion...");
            while ((aes_done !== 1'b1) &&
                   (timeout_count < AES_TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                timeout_count = timeout_count + 1;
                if ((timeout_count % 200) == 0)
                    report_aes_status();
            end

            report_aes_status();
            check(aes_done === 1'b1, "AES done asserted");
            check(aes_busy === 1'b0, "AES busy deasserted");

            if (aes_done !== 1'b1)
                $fatal(1, "[MONITOR] AES completion timeout");
        end
    endtask

    task automatic read_result(output reg [127:0] result);
        integer b;
        begin
            result = 128'b0;

            if ({sib1_enable,sib2_enable,sib3_enable} !== 3'b111)
                open_all_sibs();

            enter_shift_dr_safely();

            $display("[MONITOR] Wrapper result=%032h",
                     dut.u_aes_ijtag_wrapper.result_reg);

            // Sample TDO before each active shift edge, LSB first.
            for (b = 0; b < 128; b = b + 1) begin
                @(negedge tck);
                tms = (b == 127);
                tdi = 1'b0;
                #1;
                result[b] = tdo;
                @(posedge tck);
                #1;
            end

            drive_cycle(1'b1, 1'b0); // Exit1-DR -> Update-DR
            drive_cycle(1'b0, 1'b0); // Update-DR -> Run-Test/Idle
        end
    endtask

    task automatic run_transaction(
        input reg mode,
        input [127:0] input_block,
        output reg [127:0] output_block
    );
        begin
            // Set the mode before reset/releasing reset so it is stable
            // throughout the AES configuration write.
            decrypt_mode = mode;
            payload = {
                256'h603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4,
                input_block
            };

            reset_environment();
            load_instruction(IJTAG_INSTR);
            check(select_ijtag === 1'b1, "IJTAG instruction selected");
            open_all_sibs();
            load_aes_payload(payload);

            // Restore the scan path if payload shifting changed SIB states.
            if ({sib1_enable,sib2_enable,sib3_enable} !== 3'b111)
                open_all_sibs();
            
            check(
                {sib1_enable,sib2_enable,sib3_enable} === 3'b111,
                "SIB path open before AES result readout"
            );

            $display("[MONITOR] decrypt_mode=%b", decrypt_mode);
            $display("[MONITOR] Loaded key       = %064h",
                     dut.u_aes_ijtag_wrapper.key_reg);
            $display("[MONITOR] Loaded input     = %032h",
                     dut.u_aes_ijtag_wrapper.block_reg);

            check(
                dut.u_aes_ijtag_wrapper.key_reg === payload[383:128],
                "AES-256 key loaded correctly"
            );
            check(
                dut.u_aes_ijtag_wrapper.block_reg === payload[127:0],
                "Input block loaded correctly"
            );

            wait_for_aes();
            read_result(output_block);
        end
    endtask

    initial begin : run_test
        errors = 0;
        checks = 0;
        timeout_count = 0;

        tms = 1'b1;
        tdi = 1'b0;
        decrypt_mode = 1'b0;
        trst_n = 1'b0;
        reset_n = 1'b0;

        expected_ciphertext = 128'hf3eed1bdb5d2a03c064b5a7e3db181f8;
        expected_plaintext  = 128'h6bc1bee22e409f96e93d7e117393172a;

        $display("");
        $display("====================================================");
        $display(" IJTAG + AES-256 ENCRYPTION AND DECRYPTION TEST");
        $display("====================================================");

        test_sib3_bypass();

        // First transaction: encryption.
        $display("\n[TEST 1] AES-256 ENCRYPTION");
        run_transaction(
            1'b0,
            128'h6bc1bee22e409f96e93d7e117393172a,
            ciphertext
        );

        $display("[SCOREBOARD] Expected ciphertext: %032h", expected_ciphertext);
        $display("[SCOREBOARD] Observed ciphertext: %032h", ciphertext);
        check(
            ciphertext === expected_ciphertext,
            "AES-256 encryption known-answer vector"
        );

        // Second transaction: decryption of the known-answer ciphertext.
        // A fresh reset occurs inside run_transaction; mode is set first.
        $display("\n[TEST 2] AES-256 DECRYPTION");
        run_transaction(
            1'b1,
            expected_ciphertext,
            recovered_plaintext
        );

        $display("[SCOREBOARD] Expected plaintext : %032h", expected_plaintext);
        $display("[SCOREBOARD] Recovered plaintext: %032h", recovered_plaintext);
        check(
            recovered_plaintext === expected_plaintext,
            "AES-256 decryption recovers original plaintext"
        );

        // Randomized round-trip trials. The key remains fixed so each trial
        // exercises randomized data through the existing IJTAG/AES path.
        // The fixed known-answer tests above independently check correctness.
        $display("\n[TEST 3] RANDOMIZED AES-256 ROUND-TRIP TESTS");
        for (bit_index = 0; bit_index < 10; bit_index = bit_index + 1) begin
            expected_plaintext = {
                $urandom, $urandom, $urandom, $urandom
            };

            $display("[RANDOM] Trial %0d plaintext: %032h",
                     bit_index + 1, expected_plaintext);

            run_transaction(1'b0, expected_plaintext, ciphertext);
            run_transaction(1'b1, ciphertext, recovered_plaintext);

            $display("[RANDOM] Trial %0d recovered:  %032h",
                     bit_index + 1, recovered_plaintext);
            check(
                recovered_plaintext === expected_plaintext,
                "Randomized AES-256 encrypt/decrypt round trip"
            );
        end

        $display("");
        $display("================ TEST SUMMARY ================");
        $display("Checks executed : %0d", checks);
        $display("Checks failed   : %0d", errors);
        if (errors == 0)
            $display("FINAL RESULT: ALL TESTS PASSED");
        else
            $display("FINAL RESULT: %0d CHECK(S) FAILED", errors);
        $display("==============================================");
        $finish;
    end

    initial begin : global_timeout
        #200000;
        $display("[TIMEOUT] Global simulation timeout.");
        $finish;
    end

endmodule
