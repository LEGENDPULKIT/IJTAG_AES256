# IJTAG + AES UVM testbench

New UVM files are separate from the existing layered bench. No design RTL or
tb_ijtag_aes_top.sv is overwritten.

Add ijtag_aes_if.sv, ijtag_aes_uvm_pkg.sv, and tb_ijtag_aes_uvm.sv to Vivado
sim_1 in that dependency order. Set the simulation top to tb_ijtag_aes_uvm,
update compile order, launch behavioral simulation, then enter run -all in the
simulator Tcl console. To return to the old bench, set the top to
tb_ijtag_aes_top.

The suite includes the SIB3 bypass/isolation check, AES known-answer encrypt
and decrypt, and ten randomized round trips. Current RTL is expected to report
the known SIB3 isolation failure.
