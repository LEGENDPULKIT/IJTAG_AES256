`timescale 1ns/1ps
module tb_ijtag_aes_uvm;
 import uvm_pkg::*;import ijtag_aes_uvm_pkg::*;
 ijtag_aes_if v();
 ijtag_aes_top dut(.tck(v.tck),.clk(v.clk),.trst_n(v.trst_n),.reset_n(v.reset_n),
  .tms(v.tms),.tdi(v.tdi),.decrypt_mode(v.decrypt_mode),.tdo(v.tdo),
  .aes_busy(v.aes_busy),.aes_done(v.aes_done),.sib1_enable(v.sib1_enable),
  .sib2_enable(v.sib2_enable),.sib3_enable(v.sib3_enable),.select_ijtag(v.select_ijtag));
 assign v.tap_state=dut.u_jtag_tap.state;
 assign v.aes_shift_count=dut.u_aes_ijtag_wrapper.shift_count;
 initial begin v.clk=0;v.tck=0;v.trst_n=0;v.reset_n=0;v.tms=1;v.tdi=0;v.decrypt_mode=0;end
 always #5 begin v.clk=~v.clk;v.tck=~v.tck;end
 initial begin uvm_config_db #(virtual ijtag_aes_if)::set(null,"*","vif",v);run_test("ijtag_aes_uvm_test");end
endmodule
