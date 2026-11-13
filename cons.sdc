# Timing constraints for the AES-integrated IJTAG top (ijtag_aes_top).
#
# ASSUMPTIONS from the supplied notes/testbench:
#   * clk period = 10 ns
#   * tck period = 10 ns
#   * input and output interface delays = 0.5 ns
#
# Replace these assumptions with the actual ASIC/scan timing requirements
# supplied by your mentor before using this as a sign-off constraint file.

# Use nanoseconds as the time unit for this SDC.
set_units -time ns

set EXTCLK_PERIOD 10.0
set TCK_PERIOD    10.0
set SKEW          0.200
set INPUT_DELAY   0.5
set OUTPUT_DELAY  0.5

# The AES datapath is clocked by clk. TAP, IJTAG, and SIB scan logic use tck.
create_clock -name EXTCLK -period $EXTCLK_PERIOD \
    -waveform [list 0.0 [expr {$EXTCLK_PERIOD / 2.0}]] [get_ports {clk}]
create_clock -name TCK -period $TCK_PERIOD \
    -waveform [list 0.0 [expr {$TCK_PERIOD / 2.0}]] [get_ports {tck}]

# Model clock uncertainty and input clock edge transition for both clocks.
set_clock_uncertainty $SKEW [get_clocks {EXTCLK TCK}]
set_clock_transition 0.20 [get_clocks {EXTCLK TCK}]

# Input delays for the scan controls, referenced to the scan clock.
set_input_delay -min 0.0         -clock [get_clocks {TCK}] \
    [get_ports {tms tdi}]
set_input_delay -max $INPUT_DELAY -clock [get_clocks {TCK}] \
    [get_ports {tms tdi}]

# AES mode is sampled in the clk domain. Reset inputs are asynchronous and
# therefore are intentionally not assigned ordinary synchronous input delays.
set_input_delay -min 0.0         -clock [get_clocks {EXTCLK}] \
    [get_ports {decrypt_mode}]
set_input_delay -max $INPUT_DELAY -clock [get_clocks {EXTCLK}] \
    [get_ports {decrypt_mode}]

# Scan/TAP outputs are referenced to tck; AES status outputs to clk.
set_output_delay -min 0.0          -clock [get_clocks {TCK}] \
    [get_ports {tdo sib1_enable sib2_enable sib3_enable select_ijtag}]
set_output_delay -max $OUTPUT_DELAY -clock [get_clocks {TCK}] \
    [get_ports {tdo sib1_enable sib2_enable sib3_enable select_ijtag}]

set_output_delay -min 0.0          -clock [get_clocks {EXTCLK}] \
    [get_ports {aes_busy aes_done}]
set_output_delay -max $OUTPUT_DELAY -clock [get_clocks {EXTCLK}] \
    [get_ports {aes_busy aes_done}]
