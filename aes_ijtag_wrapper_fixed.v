`timescale 1ns / 1ps

// ============================================================================
// AES-256 IJTAG instrument wrapper
// ============================================================================
// Scan payload: 384 bits, shifted LSB-first by the testbench
//   payload[383:128] = 256-bit AES key
//   payload[127:0]   = 128-bit plaintext
//
// Sequence:
//   1. Shift 384 bits through the IJTAG instrument.
//   2. After the 384th bit, the wrapper automatically programs the supplied
//      AES core and starts one AES-256 encryption.
//   3. When AES reports result_valid, capture_dr loads the 128-bit ciphertext
//      into scan_reg[127:0].
//   4. Shift out ciphertext LSB-first through instrument_tdo.
//
// The supplied AES RTL is NOT modified. This wrapper uses its existing
// memory-mapped interface.
// ============================================================================

module aes_ijtag_wrapper (
    input  wire        clk,
    input  wire        reset_n,

    input  wire        instrument_tdi,
    output wire        instrument_tdo,

    input  wire        capture_dr,
    input  wire        shift_dr,

    output wire        aes_busy,
    output wire        aes_done
);

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_LOAD_KEY   = 4'd1;
    localparam [3:0] ST_CONFIG_KEY = 4'd2;
    localparam [3:0] ST_INIT       = 4'd3;
    localparam [3:0] ST_WAIT_INIT  = 4'd4;
    localparam [3:0] ST_LOAD_BLOCK = 4'd5;
    localparam [3:0] ST_NEXT       = 4'd6;
    localparam [3:0] ST_WAIT_VALID = 4'd7;
    localparam [3:0] ST_READ_RESULT= 4'd8;
    localparam [3:0] ST_DONE       = 4'd9;
    localparam [3:0] ST_WAIT_INIT_BUSY = 4'd10;

    reg [383:0] scan_reg;
    reg [8:0]   shift_count;

    reg [255:0] key_reg;
    reg [127:0] block_reg;
    reg [127:0] result_reg;

    reg [3:0] state;
    reg [3:0] word_index;

    reg        busy_reg;
    reg        done_reg;

    // AES memory-mapped bus.
    reg        aes_cs;
    reg        aes_we;
    reg [7:0]  aes_address;
    reg [31:0] aes_write_data;
    wire [31:0] aes_read_data;

    // Supplied AES core.
    aes aes_core_inst (
        .clk        (clk),
        .reset_n    (reset_n),
        .cs         (aes_cs),
        .we         (aes_we),
        .address    (aes_address),
        .write_data (aes_write_data),
        .read_data   (aes_read_data)
    );

    assign instrument_tdo = shift_dr ? scan_reg[0] : 1'b0;
    assign aes_busy = busy_reg;
    assign aes_done = done_reg;

    // ------------------------------------------------------------------------
    // AES bus is combinational. The AES core samples these signals on clk.
    // ------------------------------------------------------------------------
    always @(*)
    begin
        aes_cs         = 1'b0;
        aes_we         = 1'b0;
        aes_address    = 8'h00;
        aes_write_data = 32'h00000000;

        if (busy_reg)
        begin
            case (state)
                ST_LOAD_KEY:
                begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h10 + word_index;
                    aes_write_data = key_reg[255 - (word_index * 32) -: 32];
                end

                ST_CONFIG_KEY:
                begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h0A;
                    // Secworks AES core: keylen=1 selects AES-256 and encdec=1 selects encryption.
                    aes_write_data = 32'h00000003;
                end

                ST_INIT:
                begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h08;
                    // INIT = 1
                    aes_write_data = 32'h00000001;
                end

                ST_LOAD_BLOCK:
                begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h20 + word_index;
                    aes_write_data = block_reg[127 - (word_index * 32) -: 32];
                end

                ST_NEXT:
                begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h08;
                    // NEXT = 1
                    aes_write_data = 32'h00000002;
                end

                ST_WAIT_INIT_BUSY,
                ST_WAIT_INIT,
                ST_WAIT_VALID:
                begin
                    aes_cs      = 1'b1;
                    aes_we      = 1'b0;
                    aes_address = 8'h09;
                end

                ST_READ_RESULT:
                begin
                    aes_cs      = 1'b1;
                    aes_we      = 1'b0;
                    aes_address = 8'h30 + word_index;
                end

                default:
                begin
                end
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Scan + AES control FSM.
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n)
    begin
        if (!reset_n)
        begin
            scan_reg    <= 384'b0;
            shift_count <= 9'd0;

            key_reg     <= 256'b0;
            block_reg   <= 128'b0;
            result_reg  <= 128'b0;

            state       <= ST_IDLE;
            word_index  <= 4'd0;
            busy_reg    <= 1'b0;
            done_reg    <= 1'b0;
        end
        else
        begin
            done_reg <= 1'b0;

            // ---------------------------------------------------------------
            // Capture ciphertext for scan-out.
            // ---------------------------------------------------------------
            if (capture_dr && !busy_reg && (state == ST_DONE || state == ST_IDLE))
            begin
                scan_reg <= {256'b0, result_reg};
                shift_count <= 9'd0;
            end

            // ---------------------------------------------------------------
            // Scan in the 384-bit key/plaintext payload.
            // The testbench sends payload[0] first, so after 384 clocks the
            // scan register equals the original payload.
            // ---------------------------------------------------------------
            if (shift_dr && !busy_reg && (state == ST_IDLE || state == ST_DONE))
            begin
                scan_reg <= {instrument_tdi, scan_reg[383:1]};

                // In IDLE, shifts load the 384-bit key/plaintext payload.
                // In DONE, shifts only read out the captured ciphertext.
                if (state == ST_IDLE) begin
                    if (shift_count == 9'd383)
                    begin
                        // Extract the next (post-shift) 256-bit key and
                        // 128-bit plaintext without an off-by-one error.
                        key_reg   <= {instrument_tdi, scan_reg[383:129]};
                        block_reg <= {scan_reg[128], scan_reg[127:1]};
                        shift_count <= 9'd0;
                        word_index <= 4'd0;
                        busy_reg <= 1'b1;
                        state <= ST_LOAD_KEY;
                    end
                    else
                        shift_count <= shift_count + 1'b1;
                end
            end

            if (busy_reg)
            begin
                case (state)
                    ST_LOAD_KEY:
                    begin
                        if (word_index == 4'd7)
                        begin
                            word_index <= 4'd0;
                            state <= ST_CONFIG_KEY;
                        end
                        else
                            word_index <= word_index + 1'b1;
                    end

                    ST_CONFIG_KEY:
                    begin
                        state <= ST_INIT;
                    end

                    ST_INIT:
                    begin
                        // Do not trust READY immediately after INIT: it may
                        // still reflect the idle-ready state from before INIT.
                        // First observe READY deassert, then wait for it to
                        // assert again after key expansion has completed.
                        state <= ST_WAIT_INIT_BUSY;
                    end

                    ST_WAIT_INIT_BUSY:
                    begin
                        if (aes_read_data[0] == 1'b0)
                            state <= ST_WAIT_INIT;
                    end

                           
                    ST_WAIT_INIT:
                    begin
                        if (aes_read_data[0] == 1'b1)
                        begin
                            word_index <= 4'd0;
                            state <= ST_LOAD_BLOCK;
                        end
                        else
                        begin
                            state <= ST_WAIT_INIT;
                        end
                    end 

                    ST_LOAD_BLOCK:
                    begin
                        if (word_index == 4'd3)
                        begin
                            word_index <= 4'd0;
                            state <= ST_NEXT;
                        end
                        else
                            word_index <= word_index + 1'b1;
                    end

                    ST_NEXT:
                    begin
                        state <= ST_WAIT_VALID;
                    end

                    ST_WAIT_VALID:
                    begin
                        // VALID is status bit 1.
                        if (aes_read_data[1])
                        begin
                            word_index <= 4'd0;
                            state <= ST_READ_RESULT;
                        end
                    end

                    ST_READ_RESULT:
                    begin
                        case (word_index)
                            4'd0: result_reg[127:96] <= aes_read_data;
                            4'd1: result_reg[95:64]  <= aes_read_data;
                            4'd2: result_reg[63:32]  <= aes_read_data;
                            4'd3: result_reg[31:0]   <= aes_read_data;
                            default: ;
                        endcase

                        if (word_index == 4'd3)
                        begin
                            busy_reg <= 1'b0;
                            done_reg <= 1'b1;
                            state <= ST_DONE;
                            word_index <= 4'd0;
                        end
                        else
                            word_index <= word_index + 1'b1;
                    end

                    default:
                        state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
