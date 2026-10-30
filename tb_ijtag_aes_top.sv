`timescale 1ns / 1ps

// Layered SystemVerilog testbench for the shared-AES IJTAG design.
// The 3-bit configuration register selects one shared AES instrument.
// AES wrapper in this design supports encryption only.

module tb_ijtag_aes_top;

    reg clk, tck, trst_n, reset_n, tms, tdi;
    reg decrypt_mode;

    wire tdo, aes_busy, aes_done;
    wire sib1_enable, sib2_enable, sib3_enable;
    wire select_ijtag;

    integer errors, checks, timeout_count;
    integer bit_index;

    reg [2:0] sib_config;
    reg [383:0] payload;
    reg [127:0] ciphertext;
    reg [127:0] random_plaintext;
    reg [127:0] repeat_ciphertext;
    reg [127:0] observed_config;

    localparam [3:0] IJTAG_INSTR = 4'b0010;
    localparam [3:0] SIB_CONFIG_INSTR = 4'b0011;
    localparam [3:0] TAP_SHIFT_DR = 4'd4;

// definig the AES key, plaintext and expected ciphertext for the known-answer test to load it later on
    localparam [255:0] AES_KEY =
        256'h603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4;
    localparam [127:0] AES_PLAINTEXT =
        128'h6bc1bee22e409f96e93d7e117393172a;
    localparam [127:0] AES_EXPECTED_CIPHERTEXT =
        128'hf3eed1bdb5d2a03c064b5a7e3db181f8;

    localparam integer AES_TIMEOUT_CYCLES = 20000;

    // Keep the DUT instance and its top-level signal connections unchanged.
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

    // Keep the two clocks in phase, as in the existing bench.
    always #5 begin
        clk = ~clk;
        tck = ~tck;
    end

//the function acts like a counter that can be displayed in the scoreboard 
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
                {sib3_enable,sib2_enable,sib1_enable} === 3'b000,
                "Reset clears the SIB configuration"
            );

            @(negedge tck);
            trst_n = 1'b1;
            reset_n = 1'b1;
            drive_cycle(1'b0, 1'b0); //changes the state to Run-Test/Idle
        end
    endtask

    task automatic load_instruction(input [3:0] instr);
        integer b;
        begin
            drive_cycle(1'b1, 1'b0); // Select-DR
            drive_cycle(1'b1, 1'b0); // Select-IR
            drive_cycle(1'b0, 1'b0); // Capture-IR
            drive_cycle(1'b0, 1'b0); // Shift-IR

            for (b = 0; b < 4; b = b + 1)
                drive_cycle((b == 3), instr[b]); // it runs 4 times, last time tms=1 to exit Shift-IR, so at evry iteration, 
                                                 //tms=0 except the last one, and tdi=instr[b] to shift in the instruction bits

            drive_cycle(1'b1, 1'b0); // Exit1-IR -> Update-IR
            drive_cycle(1'b0, 1'b0); // Update-IR -> Run-Test/Idle

            check(
                dut.u_jtag_tap.instruction === instr,
                "TAP instruction loaded"
            );
        end
    endtask

    task automatic enter_shift_dr;
        begin
            // Five TMS-high clocks put the TAP in Test-Logic-Reset.
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
            // The last shifted bit already moved the TAP into Exit1-DR.
            drive_cycle(1'b1, 1'b0); // Exit1-DR -> Update-DR
            drive_cycle(1'b0, 1'b0); // Update-DR -> Run-Test/Idle
        end
    endtask

    // Program the new 3-bit configuration register using instruction 0011.
    // Bits are shifted least-significant bit first, then committed in Update-DR.
    task automatic program_sib_config(input [2:0] cfg);
        integer b;
        begin
            load_instruction(SIB_CONFIG_INSTR);
            enter_shift_dr();

            for (b = 0; b < 3; b = b + 1)
                drive_cycle((b == 2), cfg[b]);

            exit_update_dr();

            check(
                {sib3_enable,sib2_enable,sib1_enable} === cfg,
                "SIB configuration register updated"
            );

            load_instruction(IJTAG_INSTR);
            check(select_ijtag === 1'b1, "IJTAG instruction selected");
        end
    endtask

    task automatic check_configuration(
        input [2:0] cfg,
        input [1:0] expected_selection,
        input reg expected_enable
    );
        begin
            $display("[CONFIG] Request=%03b", cfg);
            program_sib_config(cfg);

            check(
                dut.selected_sib === expected_selection,
                "Configuration selects the expected SIB"
            );
            check(
                dut.instrument_enable === expected_enable,
                "Instrument enable matches whether any SIB is open"
            );
        end
    endtask

    // With all SIBs closed, IJTAG scan data must use the three-bit bypass
    // register and must not clock the shared AES scan register.
    task automatic test_zero_config_bypass;
        integer b;
        begin
            $display("\n[TEST 1] ZERO CONFIGURATION BYPASS / AES ISOLATION");
            reset_environment();
            program_sib_config(3'b000);

            check(dut.selected_sib === 2'd0,
                  "Zero configuration selects no SIB");
            check(dut.instrument_enable === 1'b0,
                  "Zero configuration disables AES access");

            enter_shift_dr();

            // Three-bit bypass chain: after shifting 1,0,0, the first bit
            // emerges at TDO.
            drive_cycle(1'b0, 1'b1);
            drive_cycle(1'b0, 1'b0);
            drive_cycle(1'b0, 1'b0);
            check(tdo === 1'b1, "Zero configuration shifts through bypass");

            for (b = 0; b < 8; b = b + 1)
                drive_cycle(1'b0, b[0]);

            check(
                dut.u_shared_aes_instrument.shift_count === 9'd0,
                "Zero configuration blocks AES scan clocks"
            );
            check(aes_busy === 1'b0,
                  "AES remains idle when all SIBs are closed");
            check(aes_done === 1'b0,
                  "AES does not complete when all SIBs are closed");

            reset_environment();
        end
    endtask

    task automatic load_aes_payload(input [383:0] data);
        integer b;
        begin
            $display("[SEQUENCE] Shifting 384-bit AES payload...");
            enter_shift_dr();

            for (b = 0; b < 384; b = b + 1) begin
                @(negedge tck);
                tms = (b == 383);
                tdi = data[b];
                @(posedge tck);
                #1;
            end

            exit_update_dr();
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

            if (dut.instrument_enable !== 1'b1)
                $fatal(1, "[SEQUENCE] Shared AES instrument is not selected");
        end
    endtask

    task automatic report_aes_status;
        begin
            $display("[MONITOR] busy=%b done=%b wrapper_state=%0d",
                     aes_busy, aes_done, dut.u_shared_aes_instrument.state);
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
                if ((timeout_count % 1000) == 0)
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

            enter_shift_dr_safely();

            $display("[MONITOR] Shared AES result=%032h",
                     dut.u_shared_aes_instrument.result_reg);

            // Sample TDO before each active TCK edge; result is shifted LSB first.
            for (b = 0; b < 128; b = b + 1) begin
                @(negedge tck);
                tms = (b == 127);
                tdi = 1'b0;
                #1;
                result[b] = tdo;
                @(posedge tck);
                #1;
            end

            exit_update_dr();
        end
    endtask

    task automatic run_encryption(
        input [2:0] cfg,
        input [127:0] input_block,
        output reg [127:0] output_block
    );
        begin
            // The new wrapper is encryption-only. Keep the compatibility
            // top-level decrypt_mode input inactive.
            decrypt_mode = 1'b0;
            payload = {AES_KEY, input_block};

            reset_environment();
            program_sib_config(cfg);

            check(
                dut.instrument_enable === 1'b1,
                "Any nonzero configuration enables the shared AES instrument"
            );
            check(
                dut.selected_sib === ((cfg == 3'b001) ? 2'd1 :
                                      (cfg == 3'b010) ? 2'd2 :
                                      (cfg == 3'b100) ? 2'd3 : 2'd0),
                "Selected-SIB output follows the one-hot or multi-hot rule"
            );

            load_aes_payload(payload);

            $display("[MONITOR] Selected SIB=%0d", dut.selected_sib);
            $display("[MONITOR] Loaded key       = %064h",
                     dut.u_shared_aes_instrument.key_reg);
            $display("[MONITOR] Loaded plaintext = %032h",
                     dut.u_shared_aes_instrument.block_reg);

            check(
                dut.u_shared_aes_instrument.key_reg === payload[383:128],
                "AES-256 key loaded correctly"
            );
            check(
                dut.u_shared_aes_instrument.block_reg === payload[127:0],
                "AES input block loaded correctly"
            );

            wait_for_aes();
            read_result(output_block);
        end
    endtask

    task automatic test_configuration_register;
        integer b;
        begin
            $display("\n[TEST 0] CONFIGURATION REGISTER RESET / CAPTURE");
            reset_environment();
            load_instruction(SIB_CONFIG_INSTR);
            enter_shift_dr();

            observed_config = 3'b000;
            for (b = 0; b < 3; b = b + 1) begin
                @(negedge tck);
                tms = (b == 2);
                tdi = tdo; // Shift the sampled bit back in to preserve config.
                #1;
                observed_config[b] = tdo;
                tdi = observed_config[b];
                @(posedge tck);
                #1;
            end

            exit_update_dr();
            check(observed_config === 3'b000,
                  "Capture-DR reads the reset configuration");
            check({sib3_enable,sib2_enable,sib1_enable} === 3'b000,
                  "Readback scan preserves the reset configuration");

            load_instruction(IJTAG_INSTR);
        end
    endtask

    initial begin : run_test
        errors = 0;
        checks = 0;
        timeout_count = 0;
        bit_index = 0;

        tms = 1'b1;
        tdi = 1'b0;
        decrypt_mode = 1'b0;
        trst_n = 1'b0;
        reset_n = 1'b0;

        $display("");
        $display("====================================================");
        $display(" IJTAG SHARED AES-256 LAYERED TESTBENCH");
        $display("====================================================");

        test_configuration_register();

        $display("\n[TEST 2] ALL EIGHT SIB CONFIGURATIONS");
        check_configuration(3'b000, 2'd0, 1'b0);
        check_configuration(3'b001, 2'd1, 1'b1);
        check_configuration(3'b010, 2'd2, 1'b1);
        check_configuration(3'b011, 2'd0, 1'b1);
        check_configuration(3'b100, 2'd3, 1'b1);
        check_configuration(3'b101, 2'd0, 1'b1);
        check_configuration(3'b110, 2'd0, 1'b1);
        check_configuration(3'b111, 2'd0, 1'b1);

        test_zero_config_bypass();

        $display("\n[TEST 3] AES-256 KNOWN-ANSWER THROUGH ALL NONZERO CONFIGURATIONS");
        run_encryption(3'b001, AES_PLAINTEXT, ciphertext);
        check(ciphertext === AES_EXPECTED_CIPHERTEXT,
              "AES known-answer encryption through configuration 001");

        run_encryption(3'b010, AES_PLAINTEXT, ciphertext);
        check(ciphertext === AES_EXPECTED_CIPHERTEXT,
              "AES known-answer encryption through configuration 010");

        run_encryption(3'b011, AES_PLAINTEXT, ciphertext);
        check(ciphertext === AES_EXPECTED_CIPHERTEXT,
              "AES known-answer encryption through configuration 011");

        run_encryption(3'b100, AES_PLAINTEXT, ciphertext);
        check(ciphertext === AES_EXPECTED_CIPHERTEXT,
              "AES known-answer encryption through configuration 100");

        run_encryption(3'b101, AES_PLAINTEXT, ciphertext);
        check(ciphertext === AES_EXPECTED_CIPHERTEXT,
              "AES known-answer encryption through configuration 101");

        run_encryption(3'b110, AES_PLAINTEXT, ciphertext);
        check(ciphertext === AES_EXPECTED_CIPHERTEXT,
              "AES known-answer encryption through configuration 110");

        run_encryption(3'b111, AES_PLAINTEXT, ciphertext);
        check(ciphertext === AES_EXPECTED_CIPHERTEXT,
              "AES known-answer encryption through configuration 111");

        $display("\n[TEST 4] RANDOMIZED ENCRYPTION REPEATABILITY");
        for (bit_index = 0; bit_index < 10; bit_index = bit_index + 1) begin
            random_plaintext = {$urandom, $urandom, $urandom, $urandom};
            sib_config = $urandom;
            if (sib_config == 3'b000)
                sib_config = 3'b001;

            $display("[RANDOM] Trial %0d config=%03b plaintext=%032h",
                     bit_index + 1, sib_config, random_plaintext);

            run_encryption(sib_config, random_plaintext, ciphertext);
            run_encryption(sib_config, random_plaintext, repeat_ciphertext);

            check(
                ciphertext === repeat_ciphertext,
                "Repeated random encryption gives the same ciphertext"
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
        #1000000;
        $display("[TIMEOUT] Global simulation timeout.");
        $finish;
    end

endmodule
