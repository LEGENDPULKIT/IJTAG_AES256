package ijtag_aes_uvm_pkg;
 import uvm_pkg::*;
 `include "uvm_macros.svh"
 localparam logic [3:0] IJTAG_INSTR=4'b0010,TAP_SHIFT_DR=4'd4;
 localparam logic [255:0] AES_KEY=256'h603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4;
 localparam int AES_TIMEOUT=2000;
 typedef enum bit [1:0] {BYPASS_TEST,ENCRYPT_TEST,DECRYPT_TEST,ROUNDTRIP_TEST} op_e;

 class aes_item extends uvm_sequence_item;
  op_e op; rand bit [127:0] data; bit [127:0] expected; bit compare;
  `uvm_object_utils_begin(aes_item)
   `uvm_field_enum(op_e,op,UVM_DEFAULT) `uvm_field_int(data,UVM_DEFAULT)
   `uvm_field_int(expected,UVM_DEFAULT) `uvm_field_int(compare,UVM_DEFAULT)
  `uvm_object_utils_end
  function new(string name="aes_item"); super.new(name); endfunction
 endclass
 class aes_expect extends uvm_sequence_item;
  bit [127:0] data; bit compare;
  `uvm_object_utils_begin(aes_expect)
   `uvm_field_int(data,UVM_DEFAULT) `uvm_field_int(compare,UVM_DEFAULT)
  `uvm_object_utils_end
  function new(string name="aes_expect"); super.new(name); endfunction
 endclass
 class aes_result extends uvm_sequence_item;
  bit [127:0] data;
  `uvm_object_utils_begin(aes_result) `uvm_field_int(data,UVM_DEFAULT) `uvm_object_utils_end
  function new(string name="aes_result"); super.new(name); endfunction
 endclass
 typedef uvm_sequencer #(aes_item) aes_sequencer;

 class aes_driver extends uvm_driver #(aes_item);
  `uvm_component_utils(aes_driver)
  virtual ijtag_aes_if vif;
  uvm_analysis_port #(aes_expect) expected_ap;
  function new(string n,uvm_component p); super.new(n,p); expected_ap=new("expected_ap",this); endfunction
  function void build_phase(uvm_phase p);
   super.build_phase(p);
   if(!uvm_config_db #(virtual ijtag_aes_if)::get(this,"","vif",vif))
    `uvm_fatal("VIF","No virtual interface")
  endfunction
  task cyc(bit m,bit d);
   @(negedge vif.tck); vif.tms=m; vif.tdi=d; @(posedge vif.tck); #1;
  endtask
  task reset_env;
   @(negedge vif.tck); vif.trst_n=0; vif.reset_n=0; vif.tms=1; vif.tdi=0;
   repeat(4) @(posedge vif.tck); #1;
   if({vif.sib1_enable,vif.sib2_enable,vif.sib3_enable}!==3'b000)
    `uvm_error("RESET","SIBs did not close on reset")
   @(negedge vif.tck); vif.trst_n=1; vif.reset_n=1; cyc(0,0);
  endtask
  task ir;
   integer b;
   cyc(1,0);cyc(1,0);cyc(0,0);cyc(0,0);
   for(b=0;b<4;b=b+1) cyc((b==3),IJTAG_INSTR[b]);
   cyc(1,0);cyc(0,0);
   if(vif.select_ijtag!==1) `uvm_error("IR","IJTAG instruction not selected")
  endtask
  task enter_dr;
   repeat(5) cyc(1,0);cyc(0,0);cyc(1,0);cyc(0,0);cyc(0,0);
   if(vif.tap_state!==TAP_SHIFT_DR) `uvm_fatal("TAP","Could not enter Shift-DR")
  endtask
  task exit_dr; cyc(1,0);cyc(1,0);cyc(0,0); endtask
  task sib1;
   if(vif.sib1_enable!==1) begin enter_dr();cyc(1,1);exit_dr();end
   if(vif.sib1_enable!==1) `uvm_fatal("SIB","SIB1 did not open")
  endtask
  task sib2;
   if(vif.sib2_enable!==1) begin enter_dr();cyc(0,1);cyc(1,1);exit_dr();end
   if({vif.sib1_enable,vif.sib2_enable}!==2'b11) `uvm_fatal("SIB","SIB2 did not open")
  endtask
  task sibs_open;
   sib1();sib2();
   if(vif.sib3_enable!==1) begin enter_dr();cyc(0,1);cyc(0,1);cyc(1,1);exit_dr();end
   if({vif.sib1_enable,vif.sib2_enable,vif.sib3_enable}!==3'b111)
    `uvm_fatal("SIB","All SIBs did not open")
  endtask
  task bypass;
   integer b;
   reset_env();ir();sib1();sib2();
   if({vif.sib1_enable,vif.sib2_enable,vif.sib3_enable}!==3'b110)
    `uvm_error("BYPASS","Expected only SIB3 closed")
   enter_dr();cyc(0,1);
   if(vif.tdo!==1) `uvm_error("BYPASS","Closed SIB3 TDO bypass failed")
   for(b=1;b<8;b=b+1) cyc(0,0);
   if(vif.aes_shift_count!==9'd0)
    `uvm_error("BYPASS",$sformatf("AES scan counter advanced: %0d",vif.aes_shift_count))
   if(vif.aes_busy!==0) `uvm_error("BYPASS","AES became busy with SIB3 closed")
   reset_env();
  endtask
  task payload_shift(logic [383:0] pld);
   integer b; enter_dr();
   for(b=0;b<384;b=b+1) begin
    @(negedge vif.tck);vif.tms=(b==383);vif.tdi=pld[b];
    @(posedge vif.tck);#1;
   end
   cyc(1,0);cyc(0,0);
  endtask
  task enter_dr_safe;
   case(vif.tap_state)
    4'd4:begin end
    4'd3:cyc(0,0);
    4'd6:begin cyc(1,0);cyc(0,0);end
    4'd7:cyc(0,0);
    4'd1:begin cyc(1,0);cyc(0,0);cyc(0,0);end
    4'd2:begin cyc(0,0);cyc(0,0);end
    default:`uvm_fatal("TAP","Invalid state before result scan")
   endcase
   #1;if(vif.tap_state!==TAP_SHIFT_DR) `uvm_fatal("TAP","Failed result Shift-DR")
  endtask
  task result_shift(output logic [127:0] value);
   integer b;value='0;
   if({vif.sib1_enable,vif.sib2_enable,vif.sib3_enable}!==3'b111)sibs_open();
   enter_dr_safe();
   for(b=0;b<128;b=b+1)begin
    @(negedge vif.tck);vif.tms=(b==127);vif.tdi=0;#1;value[b]=vif.tdo;
    @(posedge vif.tck);#1;
   end
   cyc(1,0);cyc(0,0);
  endtask
  task aes_run(bit dec,logic [127:0] din,output logic [127:0] dout);
   integer n;logic [383:0] pld;
   vif.decrypt_mode=dec;reset_env();ir();sibs_open();
   pld={AES_KEY,din};payload_shift(pld);
   if({vif.sib1_enable,vif.sib2_enable,vif.sib3_enable}!==3'b111)sibs_open();
   n=0;while(vif.aes_done!==1 && n<AES_TIMEOUT)begin @(posedge vif.clk);#1;n=n+1;end
   if(vif.aes_done!==1) `uvm_fatal("AES","AES timeout")
   if(vif.aes_busy!==0) `uvm_error("AES","Busy remained high after done")
   result_shift(dout);
  endtask
  task exp_write(logic [127:0] d,bit c);
   aes_expect e;e=aes_expect::type_id::create("exp");e.data=d;e.compare=c;expected_ap.write(e);
  endtask
  task run_phase(uvm_phase phase);
   aes_item req,rsp;logic [127:0] a,b;
   forever begin
    seq_item_port.get_next_item(req);
    case(req.op)
     BYPASS_TEST:begin bypass();a='0;end
     ENCRYPT_TEST:begin exp_write(req.expected,req.compare);aes_run(0,req.data,a);end
     DECRYPT_TEST:begin exp_write(req.expected,req.compare);aes_run(1,req.data,a);end
     ROUNDTRIP_TEST:begin
      exp_write('0,0);aes_run(0,req.data,a);
      exp_write(req.expected,1);aes_run(1,a,b);a=b;
     end
     default:`uvm_fatal("OP","Unknown sequence operation")
    endcase
    rsp=aes_item::type_id::create("rsp");rsp.set_id_info(req);rsp.data=a;
    seq_item_port.item_done(rsp);
   end
  endtask
 endclass

 class aes_monitor extends uvm_monitor;
  `uvm_component_utils(aes_monitor)
  virtual ijtag_aes_if vif;uvm_analysis_port #(aes_result) result_ap;
  bit pending;integer count;logic [127:0] bits_out;
  covergroup cov with function sample(bit a,bit b,bit c,bit m,bit busy,bit done);
   cp_sibs:coverpoint {a,b,c};cp_mode:coverpoint m;cp_busy:coverpoint busy;cp_done:coverpoint done;
   sib_mode:cross cp_sibs,cp_mode;
  endgroup
  function new(string n,uvm_component p);
   super.new(n,p);result_ap=new("result_ap",this);cov=new();pending=0;count=0;bits_out='0;
  endfunction
  function void build_phase(uvm_phase p);
   super.build_phase(p);
   if(!uvm_config_db #(virtual ijtag_aes_if)::get(this,"","vif",vif)) `uvm_fatal("VIF","No virtual interface")
  endfunction
  task run_phase(uvm_phase p);
   aes_result r;
   forever begin
    @(negedge vif.tck);
    if(vif.sib1_enable!==1'bx && vif.sib2_enable!==1'bx && vif.sib3_enable!==1'bx &&
       vif.decrypt_mode!==1'bx && vif.aes_busy!==1'bx && vif.aes_done!==1'bx)
     cov.sample(vif.sib1_enable,vif.sib2_enable,vif.sib3_enable,vif.decrypt_mode,vif.aes_busy,vif.aes_done);
    if(vif.aes_done===1) pending=1;
    if(pending && vif.tap_state===TAP_SHIFT_DR &&
       {vif.sib1_enable,vif.sib2_enable,vif.sib3_enable}===3'b111)begin
     bits_out[count]=vif.tdo;count=count+1;
     if(count==128)begin r=aes_result::type_id::create("result");r.data=bits_out;
      result_ap.write(r);pending=0;count=0;bits_out='0;end
    end
   end
  endtask
  function void report_phase(uvm_phase p);
   super.report_phase(p);`uvm_info("COVERAGE",$sformatf("SIB/mode coverage %0.1f%%",cov.get_coverage()),UVM_LOW)
  endfunction
 endclass

 class aes_agent extends uvm_agent;
  `uvm_component_utils(aes_agent)
  aes_sequencer seqr;aes_driver drv;aes_monitor mon;
  function new(string n,uvm_component p);super.new(n,p);endfunction
  function void build_phase(uvm_phase p);
   super.build_phase(p);is_active=UVM_ACTIVE;
   seqr=aes_sequencer::type_id::create("seqr",this);
   drv=aes_driver::type_id::create("drv",this);mon=aes_monitor::type_id::create("mon",this);
  endfunction
  function void connect_phase(uvm_phase p);
   super.connect_phase(p);drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction
 endclass

 class aes_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(aes_scoreboard)
  uvm_tlm_analysis_fifo #(aes_expect) exp_fifo;uvm_tlm_analysis_fifo #(aes_result) got_fifo;
  function new(string n,uvm_component p);super.new(n,p);endfunction
  function void build_phase(uvm_phase p);
   super.build_phase(p);exp_fifo=new("exp_fifo",this);got_fifo=new("got_fifo",this);
  endfunction
  function void check_phase(uvm_phase p);
   aes_expect e;aes_result r;integer n;super.check_phase(p);n=0;
   while(exp_fifo.try_get(e))begin
    if(!got_fifo.try_get(r)) `uvm_error("SCOREBOARD","Missing AES scan result")
    else if(e.compare)begin n=n+1;
     if(r.data!==e.data) `uvm_error("AES_MISMATCH",$sformatf("Expected %032h got %032h",e.data,r.data))
     else `uvm_info("AES_MATCH",$sformatf("Matched %032h",r.data),UVM_LOW)
    end
   end
   if(got_fifo.try_get(r)) `uvm_error("SCOREBOARD","Unexpected AES scan result")
   `uvm_info("SCOREBOARD",$sformatf("Compared %0d results",n),UVM_LOW)
  endfunction
 endclass

 class aes_env extends uvm_env;
  `uvm_component_utils(aes_env)
  aes_agent agent;aes_scoreboard sb;
  function new(string n,uvm_component p);super.new(n,p);endfunction
  function void build_phase(uvm_phase p);
   super.build_phase(p);agent=aes_agent::type_id::create("agent",this);sb=aes_scoreboard::type_id::create("sb",this);
  endfunction
  function void connect_phase(uvm_phase p);
   super.connect_phase(p);
   agent.drv.expected_ap.connect(sb.exp_fifo.analysis_export);
   agent.mon.result_ap.connect(sb.got_fifo.analysis_export);
  endfunction
 endclass

 class aes_sequence extends uvm_sequence #(aes_item);
  `uvm_object_utils(aes_sequence)
  function new(string n="aes_sequence");super.new(n);endfunction
  task send(op_e op,logic [127:0] d,logic [127:0] e);
   aes_item q,r;q=aes_item::type_id::create("item");start_item(q);
   q.op=op;q.data=d;q.expected=e;q.compare=1;finish_item(q);get_response(r);
  endtask
  task body();
   aes_item q,r;logic [127:0] pt,ct;integer i;
   pt=128'h6bc1bee22e409f96e93d7e117393172a;
   ct=128'hf3eed1bdb5d2a03c064b5a7e3db181f8;
   q=aes_item::type_id::create("bypass");start_item(q);
   q.op=BYPASS_TEST;q.data='0;q.expected='0;q.compare=0;finish_item(q);get_response(r);
   send(ENCRYPT_TEST,pt,ct);send(DECRYPT_TEST,ct,pt);
   for(i=0;i<10;i=i+1)begin
    q=aes_item::type_id::create($sformatf("rand_%0d",i));start_item(q);
    if(!q.randomize()) `uvm_fatal("RAND","Plaintext randomization failed")
    q.op=ROUNDTRIP_TEST;q.expected=q.data;q.compare=1;finish_item(q);get_response(r);
    `uvm_info("RANDOM",$sformatf("Trial %0d recovered %032h",i+1,r.data),UVM_LOW)
   end
  endtask
 endclass

 class ijtag_aes_uvm_test extends uvm_test;
  `uvm_component_utils(ijtag_aes_uvm_test)
  aes_env env;
  function new(string n,uvm_component p);super.new(n,p);endfunction
  function void build_phase(uvm_phase p);
   super.build_phase(p);env=aes_env::type_id::create("env",this);
  endfunction
  task run_phase(uvm_phase p);
   aes_sequence s;p.raise_objection(this);s=aes_sequence::type_id::create("seq");
   s.start(env.agent.seqr);p.drop_objection(this);
  endtask
 endclass
endpackage
