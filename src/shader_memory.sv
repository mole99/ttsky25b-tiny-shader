// SPDX-FileCopyrightText: © 2024 Leo Moser <leo.moser@pm.me>
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module shader_memory #(
    parameter NUM_INSTR = 8
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        shift_i,
    input  logic        load_i,
    input  logic [7:0]  instr_i,
    output logic [7:0]  instr_o
);
    logic [7:0] memory [NUM_INSTR];
    logic [7:0] last_instr;
    
    // Load a new word from externally
    // Else just shift circularily
    assign last_instr = load_i ? instr_i : memory[0];
    
    generate
    
    `ifndef SIM
    wire [7:0] delay [NUM_INSTR];
    genvar i, j;
    for (i=0; i<NUM_INSTR; i++) begin : gen_delays
        for (j=0; j<8; j++) begin : gen_bits
            if (i < NUM_INSTR-1) begin : gen_other
                sky130_fd_sc_hd__dlygate4sd3_1 i_delay (
                    `ifdef USE_POWER_PINS
                    .VPWR(1'b1),
                    .VGND(1'b0),
                    .VPB (1'b1),
                    .VNB (1'b0),
                    `endif
                    .A   (memory[i+1][j]),
                    .X   (delay[i][j])
                );
            end else begin : gen_last
                sky130_fd_sc_hd__dlygate4sd3_1 i_delay (
                    `ifdef USE_POWER_PINS
                    .VPWR(1'b1),
                    .VGND(1'b0),
                    .VPB (1'b1),
                    .VNB (1'b0),
                    `endif
                    .A   (last_instr[j]),
                    .X   (delay[i][j])
                );
            end
        end
    end
    `endif
    
    endgenerate

    // Initialize the memory on reset 
    // Shift the memory by a whole word if shift_i is high
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            `ifdef COCOTB_SIM
            /*for (int i=0; i<NUM_INSTR; i++) begin
                memory[i] <= 8'b01_00_00_00; // NOP
            end*/
            $readmemb("../sw/binary/test4.bit", memory);
            `else
            // Load the default program (test4)
            memory[0] <= 8'b00_0100_00; // GETX R0
            memory[1] <= 8'b00_0101_01; // GETY R1
            memory[2] <= 8'b01_11_01_00; // XOR R0 R1
            memory[3] <= 8'b00_0110_10; // GETTIME R2
            memory[4] <= 8'b10_01_10_00; // ADD R0 R2
            memory[5] <= 8'b00_0000_00; // SETRGB R0
            memory[6] <= 8'b01_00_00_00; // NOP
            memory[7] <= 8'b01_00_00_00; // NOP
            memory[8] <= 8'b01_00_00_00; // NOP
            memory[9] <= 8'b01_00_00_00; // NOP
            memory[10] <= 8'b01_00_00_00; // NOP
            memory[11] <= 8'b01_00_00_00; // NOP
            memory[12] <= 8'b01_00_00_00; // NOP
            memory[13] <= 8'b01_00_00_00; // NOP
            memory[14] <= 8'b01_00_00_00; // NOP
            memory[15] <= 8'b01_00_00_00; // NOP
            `endif
        end else begin
            if (shift_i) begin
                for (int n=0; n<NUM_INSTR; n++) begin
                    `ifdef SIM
                    if (i < NUM_INSTR-1) begin
                        memory[i] <= memory[i+1];
                    end else begin
                        // Load a new word from externally
                        if (load_i) begin
                            memory[i] <= instr_i;
                        // Else just shift circularily
                        end else begin
                            memory[i] <= memory[0];
                        end
                    end
                    `else
                    memory[n] <= delay[n];
                    `endif
                end
            end
        end
    end
    
    assign instr_o = memory[0];

endmodule
