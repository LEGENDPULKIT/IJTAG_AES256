
`timescale 1ns / 1ps

// ============================================================================
// AES-256 IJTAG instrument wrapper
// ============================================================================
// Scan payload: 384 bits, shifted LSB-first by the testbench
//   payload[383:128] = 256-bit AES key
//   payload[127:0]   = input block:
//                       plaintext for encryption
//                       ciphertext for decryption
//
// decrypt_mode = 0: AES-256 encryption
// decrypt_mode = 1: AES-256 decryption
//
// The supplied AES RTL is unchanged.
// Temporary simulation debug prints report AES register transactions.
// ============================================================================

module aes_ijtag_wrapper (
    input  wire        clk,
    input  wire        reset_n,

    input  wire        instrument_tdi,
    output wire        instrument_tdo,

    input  wire        capture_dr,
    input  wire        shift_dr,
    input  wire        decrypt_mode,

    output wire        aes_busy,
    output wire        aes_done
);

    localparam [3:0] ST_IDLE        = 4'd0;
    localparam [3:0] ST_LOAD_KEY    = 4'd1;
    localparam [3:0] ST_CONFIG_KEY  = 4'd2;
    localparam [3:0] ST_INIT        = 4'd3;
    localparam [3:0] ST_WAIT_INIT   = 4'd4;
    localparam [3:0] ST_LOAD_BLOCK  = 4'd5;
    localparam [3:0] ST_NEXT        = 4'd6;
    localparam [3:0] ST_WAIT_VALID  = 4'd7;
    localparam [3:0] ST_READ_RESULT = 4'd8;
    localparam [3:0] ST_DONE        = 4'd9;

    reg [383:0] scan_reg;
    reg [8:0]   shift_count;

    reg [255:0] key_reg;
    reg [127:0] block_reg;
    reg [127:0] result_reg;

    reg [3:0] state;
    reg [3:0] word_index;

    reg busy_reg;
    reg done_reg;
    reg init_busy_seen;

    // AES memory-mapped bus.
    reg         aes_cs;
    reg         aes_we;
    reg [7:0]   aes_address;
    reg [31:0]  aes_write_data;
    wire [31:0] aes_read_data;

    // Original AES core: do not modify its implementation.
    aes aes_core_inst (
        .clk        (clk),
        .reset_n    (reset_n),
        .cs         (aes_cs),
        .we         (aes_we),
        .address    (aes_address),
        .write_data (aes_write_data),
        .read_data  (aes_read_data)
    );

    assign instrument_tdo = shift_dr ? scan_reg[0] : 1'b0;
    assign aes_busy = busy_reg;
    assign aes_done = done_reg;

    // ------------------------------------------------------------------------
    // AES bus control.
    // ------------------------------------------------------------------------
    always @(*) begin
        aes_cs         = 1'b0;
        aes_we         = 1'b0;
        aes_address    = 8'h00;
        aes_write_data = 32'h00000000;

        if (busy_reg) begin
            case (state)

                ST_LOAD_KEY: begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h10 + word_index;
                    aes_write_data =
                        key_reg[255 - (word_index * 32) -: 32];
                end

                ST_CONFIG_KEY: begin
                    aes_cs      = 1'b1;
                    aes_we      = 1'b1;
                    aes_address = 8'h0A;

                    // Config bit 1 = keylen = 1 (AES-256).
                    // Config bit 0 = encdec:
                    //   1 = encryption
                    //   0 = decryption
                    aes_write_data =
                        decrypt_mode ? 32'h00000002 : 32'h00000003;
                end

                ST_INIT: begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h08;
                    aes_write_data = 32'h00000001;
                end

                ST_LOAD_BLOCK: begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h20 + word_index;
                    aes_write_data =
                        block_reg[127 - (word_index * 32) -: 32];
                end

                ST_NEXT: begin
                    aes_cs         = 1'b1;
                    aes_we         = 1'b1;
                    aes_address    = 8'h08;
                    aes_write_data = 32'h00000002;
                end

                ST_WAIT_INIT,
                ST_WAIT_VALID: begin
                    aes_cs      = 1'b1;
                    aes_we      = 1'b0;
                    aes_address = 8'h09;
                end

                ST_READ_RESULT: begin
                    aes_cs      = 1'b1;
                    aes_we      = 1'b0;
                    aes_address = 8'h30 + word_index;
                end

                default: begin
                    // Bus remains inactive.
                end

            endcase
        end
    end

    // ------------------------------------------------------------------------
    // TEMPORARY AES BUS DEBUG MONITOR.
    // Simulation only. Remove after debugging.
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset_n && aes_cs) begin
            if (aes_we) begin
                $display(
                    "[AES BUS WRITE] time=%0t state=%0d address=0x%02h data=0x%08h",
                    $time, state, aes_address, aes_write_data
                );
            end
            else begin
                $display(
                    "[AES BUS READ ] time=%0t state=%0d address=0x%02h data=0x%08h",
                    $time, state, aes_address, aes_read_data
                );
            end
        end
    end

    // ------------------------------------------------------------------------
    // Scan input, AES control FSM, and result scan-out.
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            scan_reg       <= 384'b0;
            shift_count    <= 9'd0;

            key_reg        <= 256'b0;
            block_reg      <= 128'b0;
            result_reg     <= 128'b0;

            state          <= ST_IDLE;
            word_index     <= 4'd0;
            busy_reg       <= 1'b0;
            done_reg       <= 1'b0;
            init_busy_seen <= 1'b0;
        end
        else begin
            done_reg <= 1'b0;

            // Keep the completed result available for scan-out.
            if (!busy_reg && state == ST_DONE && !shift_dr) begin
                scan_reg    <= {256'b0, result_reg};
                shift_count <= 9'd0;
            end

            // Capture the completed result into the scan register.
            if (capture_dr && !busy_reg &&
                (state == ST_DONE || state == ST_IDLE)) begin
                scan_reg    <= {256'b0, result_reg};
                shift_count <= 9'd0;
            end

            // Shift the result out, least-significant bit first.
            if (shift_dr && !busy_reg && state == ST_DONE) begin
                scan_reg <= {1'b0, scan_reg[383:1]};
            end

            // Shift the 384-bit key + input block into the wrapper.
            if (shift_dr && !busy_reg && state == ST_IDLE) begin
                scan_reg <= {instrument_tdi, scan_reg[383:1]};

                if (shift_count == 9'd383) begin
                    // Include the final incoming bit explicitly.
                    key_reg   <= {instrument_tdi, scan_reg[383:129]};
                    block_reg <= scan_reg[128:1];

                    shift_count <= 9'd0;
                    word_index  <= 4'd0;
                    busy_reg    <= 1'b1;
                    state       <= ST_LOAD_KEY;
                end
                else begin
                    shift_count <= shift_count + 1'b1;
                end
            end

            // AES control state machine.
            if (busy_reg) begin
                case (state)

                    ST_LOAD_KEY: begin
                        if (word_index == 4'd7) begin
                            word_index <= 4'd0;
                            state      <= ST_CONFIG_KEY;
                        end
                        else begin
                            word_index <= word_index + 1'b1;
                        end
                    end

                    ST_CONFIG_KEY: begin
                        state <= ST_INIT;
                    end

                    ST_INIT: begin
                        init_busy_seen <= 1'b0;
                        state          <= ST_WAIT_INIT;
                    end

                    ST_WAIT_INIT: begin
                        // READY should go low during initialization and
                        // then return high when initialization completes.
                        if (!aes_read_data[0])
                            init_busy_seen <= 1'b1;

                        if (init_busy_seen && aes_read_data[0]) begin
                            word_index <= 4'd0;
                            state      <= ST_LOAD_BLOCK;
                        end
                    end

                    ST_LOAD_BLOCK: begin
                        if (word_index == 4'd3) begin
                            word_index <= 4'd0;
                            state      <= ST_NEXT;
                        end
                        else begin
                            word_index <= word_index + 1'b1;
                        end
                    end

                    ST_NEXT: begin
                        state <= ST_WAIT_VALID;
                    end

                    ST_WAIT_VALID: begin
                        // Status bit 1 is result_valid.
                        if (aes_read_data[1]) begin
                            word_index <= 4'd0;
                            state      <= ST_READ_RESULT;
                        end
                    end

                    ST_READ_RESULT: begin
                        case (word_index)
                            4'd0: result_reg[127:96] <= aes_read_data;
                            4'd1: result_reg[95:64]  <= aes_read_data;
                            4'd2: result_reg[63:32]  <= aes_read_data;
                            4'd3: result_reg[31:0]   <= aes_read_data;
                            default: ;
                        endcase

                        if (word_index == 4'd3) begin
                            // Use the current final read-data word directly,
                            // since result_reg's nonblocking assignment takes
                            // effect after this clock edge.
                            scan_reg <= {
                                256'b0,
                                result_reg[127:32],
                                aes_read_data
                            };

                            shift_count <= 9'd0;
                            busy_reg    <= 1'b0;
                            done_reg    <= 1'b1;
                            state       <= ST_DONE;
                            word_index  <= 4'd0;
                        end
                        else begin
                            word_index <= word_index + 1'b1;
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                    end

                endcase
            end
        end
    end

endmodule
