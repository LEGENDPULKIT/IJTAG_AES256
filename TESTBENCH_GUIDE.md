# Guide to tb_ijtag_aes_top.sv

This guide explains the current layered SystemVerilog testbench, what each section does, the order of tests, and how to interpret its output. It documents the testbench in the project; it does not change the RTL or DUT signal connections.

## 1. Purpose and design behavior

The testbench controls ijtag_aes_top through its JTAG pins. It loads TAP instructions, programs the three-bit SIB configuration register, shifts an AES key and plaintext through the IJTAG scan path, waits for AES to finish, and reads the ciphertext back.

This design has one shared AES instrument:

- Configuration 000 closes all SIBs. The IJTAG scan path uses the three-bit bypass register, and AES is disconnected.
- Any nonzero configuration enables access to the shared AES.
- One-hot configurations 001, 010, and 100 report selected_sib values 1, 2, and 3.
- Multi-hot configurations 011, 101, 110, and 111 report selected_sib=0, but instrument_enable remains 1. A selected_sib value of 0 does not by itself mean AES is disabled.

The AES wrapper supports both AES-256 encryption and decryption. The testbench
uses decrypt_mode to select the operation and checks a known-answer decrypt
transaction through the IJTAG scan path.

## 2. Test flowchart

~~~mermaid
flowchart TD
    A[Start and initialize signals and counters] --> B[Reset and read the SIB configuration register]
    B --> C[Program and check all eight SIB configurations]
    C --> D[Test configuration 000: bypass works and AES stays idle]
    D --> E[Known-answer tests for each nonzero config]
    E --> F[Program config and shift 256-bit key plus 128-bit plaintext]
    F --> G[Wait for AES done and read the 128-bit result]
    G --> H[Compare with the expected ciphertext]
    H --> I{More nonzero configs?}
    I -- Yes --> E
    I -- No --> J[Start ten randomized repeatability trials]
    J --> K[Choose a random plaintext and a nonzero config]
    K --> L[Encrypt the same input twice]
    L --> M[Compare both ciphertexts]
    M --> N{More trials?}
    N -- Yes --> J
    N -- No --> O[Print totals and finish]
~~~

The main order is in the run_test initial block. Each encryption task also makes its own checks for configuration, payload loading, and AES completion.

## 3. Declarations: signals, counters, and data

### DUT signals

- clk and tck are the design clock and JTAG test clock. They are generated together.
- trst_n and reset_n are active-low resets: 0 asserts reset, 1 releases it.
- tms steers the JTAG TAP state machine. tdi supplies instruction, configuration, and payload bits.
- tdo is the serial output from the scan path.
- aes_busy and aes_done report AES activity and completion.
- sib1_enable, sib2_enable, sib3_enable report the programmed SIB bits.
- select_ijtag indicates whether the IJTAG instruction is selected.
- decrypt_mode selects encryption when low and decryption when high.

### Scoreboard and working variables

- checks counts calls to the check task.
- errors counts checks that fail.
- timeout_count counts clock cycles while waiting for AES.
- bit_index is the randomized-test loop index. It starts at 0, so value 2 means the third trial.
- sib_config stores the three-bit configuration for a randomized trial.
- payload is the 384-bit AES input: 256-bit key followed by 128-bit plaintext.
- ciphertext stores a read-out result.
- random_plaintext stores the current random input block.
- repeat_ciphertext stores the second result when the same random input is encrypted again.
- observed_config stores configuration readback. It is declared 128 bits wide, but only the lowest three bits are used.

### Constants

- IJTAG_INSTR is 4'b0010, the instruction for the IJTAG data path.
- SIB_CONFIG_INSTR is 4'b0011, the instruction for the SIB configuration register.
- TAP_SHIFT_DR is the encoded TAP state used to check that the controller entered Shift-DR.
- AES_KEY is the fixed 256-bit key.
- AES_PLAINTEXT is the fixed 128-bit known-answer input.
- AES_EXPECTED_CIPHERTEXT is the trusted expected output for that key and input.
- AES_TIMEOUT_CYCLES is 20,000 cycles, the maximum wait for AES completion.

Hexadecimal values are compact representations of bit vectors.

## 4. DUT connection and clock generation

The ijtag_aes_top dut block connects the testbench signals to the design's top-level ports. Each named connection maps a testbench signal to a DUT port. The testbench drives the design from its top-level interface; it does not alter the DUT connections.

The clock initialization sets clk and tck low. The always block toggles both every 5 ns, giving each clock a 10 ns period. JTAG inputs are changed on a falling edge and sampled by the DUT on a rising edge, providing setup time.

## 5. Reusable helper tasks

### check(condition, label_text)

This is the scoreboard helper. Every call increments checks. If condition is exactly 1, it prints PASS. If it is 0, X, or Z, it increments errors and prints FAIL. The case-inequality test ensures unknown values cannot accidentally pass.

### drive_cycle(tm, ti)

Waits for a falling edge of tck, drives tms=tm and tdi=ti, waits for the next rising edge, and then delays 1 ns. This creates one controlled JTAG clock cycle and lets sequential logic update before the next check.

### reset_environment

Asserts both active-low resets at a falling edge, applies safe JTAG values, and holds reset for four rising edges. It checks that the SIB configuration resets to 000. Then it releases reset at a falling edge and takes the TAP toward Run-Test/Idle.

Resetting before each test transaction gives the sequence a known starting state. Changing reset on the falling edge avoids changing it at the same instant the DUT samples on the rising edge.

## 6. TAP and scan-sequence tasks

### load_instruction(instr)

The TAP has an instruction register (IR) and a data register (DR). This task moves through Select-DR, Select-IR, Capture-IR, and Shift-IR. It shifts four instruction bits, least-significant bit first. TMS is high on the final shifted bit to leave Shift-IR; the task then advances through Update-IR and returns to Run-Test/Idle.

It checks the TAP's instruction value against instr. This confirms that the intended data path is selected before scanning data.

### enter_shift_dr

Sends five TMS-high cycles to put the TAP in Test-Logic-Reset. It then follows Run-Test/Idle -> Select-DR -> Capture-DR -> Shift-DR. If the TAP is not in Shift-DR afterward, $fatal stops the simulation because continuing the scan would be unsafe.

### exit_update_dr

The final bit of a scan is sent with TMS high, leaving the TAP in Exit1-DR. This task advances Exit1-DR -> Update-DR -> Run-Test/Idle. Update-DR commits the shifted value.

### program_sib_config(cfg)

Loads SIB_CONFIG_INSTR, enters Shift-DR, and shifts cfg[0], cfg[1], cfg[2]. The third bit sets TMS high to exit the shift state. The task updates the register, checks that the three SIB enable outputs equal cfg, then loads IJTAG_INSTR and checks that IJTAG is selected.

### check_configuration(cfg, expected_selection, expected_enable)

Prints the requested config, programs it, then independently checks selected_sib and instrument_enable. The checks are separate because multi-hot configs report selected_sib=0 while still enabling the shared AES.

## 7. Configuration and bypass tests

### test_configuration_register

Resets the design, selects the SIB configuration register, and scans out its reset value. For each of the three bits it samples TDO and shifts that sampled bit back in, preserving the value. It checks that readback is 000 and that the SIB enable outputs remain 000, then selects the IJTAG instruction.

This exercises reset, Capture-DR readback, and preservation of the scanned value.

### test_zero_config_bypass

Programs 000 and checks that selected_sib=0 and instrument_enable=0. It shifts the pattern 1,0,0 and checks that the first bit emerges at TDO through the three-bit bypass register. It continues shifting and checks:

- the AES wrapper scan counter stays at zero;
- aes_busy stays 0;
- aes_done stays 0.

These checks show scan traffic uses bypass and does not reach or start AES when all SIBs are closed.

## 8. AES transaction tasks

### load_aes_payload(data)

Enters Shift-DR and shifts 384 bits, one bit per TCK cycle. It drives data[b] on TDI, with b running from 0 through 383, then exits the scan on the last bit and calls exit_update_dr.

The payload is built as {AES_KEY, input_block}. Thus payload[383:128] is the 256-bit key and payload[127:0] is the 128-bit plaintext. The wrapper's internal-register checks later confirm that these fields were captured correctly.

### enter_shift_dr_safely

Before reading a result, this task examines the current TAP state and takes only the needed transitions to Shift-DR. It handles Idle, Select-DR, Capture-DR, Pause-DR, Exit2-DR, and already being in Shift-DR. Unsupported states trigger $fatal. It also requires instrument_enable=1 before reading AES data.

### report_aes_status and wait_for_aes

report_aes_status prints aes_busy, aes_done, and the wrapper's numeric internal state for diagnosis.

wait_for_aes clears timeout_count and waits on rising clk edges until aes_done becomes 1 or the count reaches 20,000. It prints status every 1,000 cycles, then checks done=1 and busy=0. If AES does not finish, $fatal reports an AES completion timeout. The numeric wrapper state is diagnostic; done and busy are the main completion checks.

### read_result(result)

Initializes result to zero, enters Shift-DR safely, prints the internal result register for debugging, and samples 128 TDO bits into result, least-significant bit first. It exits the scan and updates the TAP afterward. This reads the result through the scan path rather than merely copying the internal register.

### run_encryption(cfg, input_block, output_block)

One complete encryption transaction:

1. Sets decrypt_mode for the selected operation and creates
   payload={AES_KEY,input_block}.
2. Resets the design.
3. Programs cfg and checks that the shared AES instrument is enabled.
4. Checks the selected_sib rule: one-hot settings report 1, 2, or 3; multi-hot settings report 0.
5. Shifts the payload.
6. Checks that the AES wrapper captured the expected key and plaintext.
7. Waits for AES done and busy to deassert.
8. Reads the 128-bit ciphertext into output_block.

## 9. Main sequence and what each test proves

The run_test initial block initializes counters and input signals, prints a banner, and calls tests in order.

### Test 0: configuration reset and readback

Calls test_configuration_register. It expects the reset configuration to be 000 and confirms the scan readback preserves it.

### All eight SIB configurations

check_configuration is called for 000, 001, 010, 011, 100, 101, 110, and 111:

| Config | selected_sib | instrument_enable | Interpretation |
|---|---:|---:|---|
| 000 | 0 | 0 | All closed; bypass |
| 001 | 1 | 1 | SIB1 open; shared AES accessible |
| 010 | 2 | 1 | SIB2 open; shared AES accessible |
| 011 | 0 | 1 | Multiple open; shared AES accessible |
| 100 | 3 | 1 | SIB3 open; shared AES accessible |
| 101 | 0 | 1 | Multiple open; shared AES accessible |
| 110 | 0 | 1 | Multiple open; shared AES accessible |
| 111 | 0 | 1 | All open; shared AES accessible |

After these configuration checks, test_zero_config_bypass verifies actual bypass data movement and AES isolation for 000.

### Test 3: known-answer AES

For every nonzero config, run_encryption encrypts AES_PLAINTEXT with AES_KEY. The returned ciphertext is compared to:

~~~text
f3eed1bdb5d2a03c064b5a7e3db181f8
~~~

This checks against a known expected answer, providing an independent correctness check for the fixed vector.

The IJTAG decrypt test then scans in the known ciphertext with the same key,
selects decrypt_mode, and checks that the scanned result equals AES_PLAINTEXT.

### Test 4: randomized repeatability

The loop runs ten trials with bit_index from 0 to 9. Each trial creates a random 128-bit plaintext from four $urandom values and a random three-bit SIB config. If the config is 000, it is changed to 001 so AES remains reachable. The test encrypts that same input twice and checks ciphertext===repeat_ciphertext.

This proves repeatability for each chosen input. It does not compare each random ciphertext with a separately calculated AES answer; the known-answer test supplies the independent AES reference check.

The printed section labels skip a number (TEST 0, TEST 1, then TEST 2/3/4). This is only a label choice; the actual execution order is the order of calls in run_test.

## 10. PASS/FAIL, counters, and timeouts

- PASS means a check condition was exactly 1.
- FAIL means a condition was 0, X, or Z; errors is incremented.
- checks is the number of checks already performed.
- errors is the number of failed checks.
- FINAL RESULT: ALL TESTS PASSED is printed if errors is zero.
- $finish ends the normal run after the summary.

The global_timeout block waits 1,000,000 ns (1 ms), then prints TIMEOUT and finishes if the main test sequence is stuck. AES_TIMEOUT_CYCLES is a separate limit: 20,000 cycles. With the 10 ns clock period, this allows up to 200,000 ns (200 microseconds) for AES completion.

The supplied log reported 379 checks, 0 failures, and finished at 187,656 ns. That indicates the run completed before the global timeout.

## 11. Reading waveform values

A waveform value is the value at the selected yellow time cursor. It may not be the final value of the simulation.

During a new randomized trial, sib_config and random_plaintext update first, and payload is built for that trial. ciphertext changes only after AES finishes and read_result completes; repeat_ciphertext changes after the second encryption. So the waveform can temporarily show the new plaintext and payload beside the previous trial's ciphertext. That is expected while an operation is in progress. Compare the outputs after both encryptions finish and the repeatability PASS appears.

Similarly, at time zero, checks and errors are still zero because the test has not executed its checks yet. For the final result, use the Tcl summary.

## 12. Glossary

- DUT: Design Under Test, here ijtag_aes_top.
- TAP: JTAG Test Access Port state machine, controlled by TMS.
- IR: Instruction Register; selects which data path is active.
- DR: Data Register; carries the selected scan data.
- SIB: Segment Insertion Bit; here the three configuration bits control access to the shared instrument.
- TDI / TDO: JTAG serial data input / output.
- Capture: Copy the selected register value into its scan path.
- Shift: Move bits serially through the selected scan register.
- Update: Commit shifted scan data to the functional configuration.
- Known-answer test: Compare a result with a trusted expected value.
- Repeatability test: Run the same input twice and confirm the outputs match.
