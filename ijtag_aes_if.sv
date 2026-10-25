interface ijtag_aes_if;
 logic clk,tck,trst_n,reset_n,tms,tdi,decrypt_mode;
 logic tdo,aes_busy,aes_done,sib1_enable,sib2_enable,sib3_enable,select_ijtag;
 logic [3:0] tap_state; logic [8:0] aes_shift_count;
endinterface
