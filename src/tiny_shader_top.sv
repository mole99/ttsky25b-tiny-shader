// SPDX-FileCopyrightText: © 2025 Leo Moser <leo.moser@pm.me>
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module tiny_shader_top (
    input  logic        clk_i, // 50.350 MHz
    input  logic        rst_ni,
    
    // SPI signals
    input  logic spi_sclk_i,
    input  logic spi_mosi_i,
    output logic spi_miso_o,
    input  logic spi_cs_i,
    
    // Pause shader execution
    // '0' = shader starts execution as normal
    // '1' = shader does not restart execution after
    //       current pixel has been finished
    input  logic pause_execute_i,
    
    // SVGA signals
    output logic [5:0] rrggbb_o,
    output logic       hsync_o,
    output logic       vsync_o,
    output logic       next_vertical_o,
    output logic       next_frame_o
);

    /* Tiny Shader Settings */
    
    localparam NUM_INSTR = 16;

    /*
        VGA 640x480 @ 60 Hz
        clock = 25.175 MHz
    */

    localparam WIDTH    = 640;
    localparam HEIGHT   = 480;
    
    localparam HFRONT   = 16;
    localparam HSYNC    = 96;
    localparam HBACK    = 48;

    localparam VFRONT   = 10;
    localparam VSYNC    = 2;
    localparam VBACK    = 33;
    
    localparam HTOTAL = WIDTH + HFRONT + HSYNC + HBACK;
    localparam VTOTAL = HEIGHT + VFRONT + VSYNC + VBACK;

    /* Horizontal and Vertical Timing */
    
    logic signed [$clog2(HTOTAL) : 0] counter_h;
    logic signed [$clog2(VTOTAL) : 0] counter_v;
    
    logic hblank;
    logic vblank;
    logic hsync;
    logic vsync;
    logic next_vertical;
    logic next_frame;

    logic clk_vga;
    
    always @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            clk_vga <= 1'b0;
        end else begin
            clk_vga <= !clk_vga;
        end
    end

    // Horizontal timing
    timing #(
        .RESOLUTION     (WIDTH),
        .FRONT_PORCH    (HFRONT),
        .SYNC_PULSE     (HSYNC),
        .BACK_PORCH     (HBACK),
        .TOTAL          (HTOTAL),
        .POLARITY       (1'b0)
    ) timing_hor (
        .clk        (clk_vga),
        .enable     (1'b1),
        .reset_n    (rst_ni),
        .inc_1_or_4 (1'b0),
        .sync       (hsync),
        .blank      (hblank),
        .next       (next_vertical),
        .counter    (counter_h)
    );

    // Vertical timing
    timing #(
        .RESOLUTION     (HEIGHT),
        .FRONT_PORCH    (VFRONT),
        .SYNC_PULSE     (VSYNC),
        .BACK_PORCH     (VBACK),
        .TOTAL          (VTOTAL),
        .POLARITY       (1'b0)
    ) timing_ver (
        .clk        (clk_vga),
        .enable     (next_vertical),
        .reset_n    (rst_ni),
        .inc_1_or_4 (1'b0),
        .sync       (vsync),
        .blank      (vblank),
        .next       (next_frame),
        .counter    (counter_v)
    );
    
    logic [8:0] cur_time;
    logic time_dir;

    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            cur_time <= '0;
            time_dir <= '0;
        end else begin
            if (next_frame) begin
                if (time_dir == 1'b0) begin
                    cur_time <= cur_time + 1;
                    if (&(cur_time+1)) begin
                        time_dir <= 1'b1;
                    end
                end else begin
                    cur_time <= cur_time - 1;
                    if (cur_time == 1) begin
                        time_dir <= 1'b0;
                    end
                end
            end
        end
    end

    /* SPI Receiver
        
        cpol       = False,
        cpha       = True,
        msb_first  = True,
        word_width = 8,
        cs_active_low = True
    */
    
    logic [7:0] memory_instr;
    logic memory_shift;
    logic memory_load;
    
    spi_receiver #(
        .REG_SIZE       (6),
        .REG_DEFAULT    (6'd42)
    ) spi_receiver_inst (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        
        // SPI signals
        .spi_sclk_i     (spi_sclk_i),
        .spi_mosi_i     (spi_mosi_i),
        .spi_miso_o     (spi_miso_o),
        .spi_cs_i       (spi_cs_i),

        // Output memory
        .memory_instr_o (memory_instr),
        .memory_shift_o (memory_shift),
        .memory_load_o  (memory_load)
    );

    // Graphics
    logic [7:0] instr;
    logic execute_shader_x, execute_shader_y, execute_shader;
    
    // Synchronizer to prevent metastability
    logic pause_execute_sync;
    synchronizer  #(
        .FF_COUNT(2)
    ) synchronizer_spi_mosi (
        .clk        (clk_i),
        .reset_n    (rst_ni),
        .in         (pause_execute_i),
        .out        (pause_execute_sync)
    );
    
    // Execute shader only when in active drawing area and not paused
    assign execute_shader_y = counter_v >= 0 && counter_v < HEIGHT;
    assign execute_shader_x = counter_h+(NUM_INSTR/2) >= 0 && counter_h+(NUM_INSTR/2) < WIDTH;
    assign execute_shader = execute_shader_x && execute_shader_y && !pause_execute_sync;

    logic execute_shader_d;
    
    always_ff @(posedge clk_i) begin
        execute_shader_d <= execute_shader;
    end

    /* Shader Memory */

    shader_memory #(
        .NUM_INSTR (NUM_INSTR)
    ) shader_memory_inst (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .shift_i    (execute_shader || memory_shift),
        .load_i     (memory_load),
        .instr_i    (memory_instr),
        .instr_o    (instr)
    );
    
    /* Count x and y positions */

    localparam WIDTH_SMALL  = WIDTH  / (NUM_INSTR/2);
    localparam HEIGHT_SMALL = HEIGHT / (NUM_INSTR/2);
    
    logic [$clog2(WIDTH_SMALL)  - 1:0] x_pos;
    logic [$clog2(HEIGHT_SMALL) - 1:0] y_pos;
    
    assign x_pos = (counter_h+(NUM_INSTR/2)) / (NUM_INSTR/2);
    assign y_pos = counter_v / (NUM_INSTR/2); // TODO
    
    /* Shader execution */
    
    logic [5:0] rgb_o;
    logic [5:0] rgb_d;

    shader_execute shader_execute_inst (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .instr_i    (instr),
        .execute    (execute_shader),
        
        .x_pos_i    (x_pos[5:0]),
        .y_pos_i    (y_pos[5:0]),
        
        .time0_i     (cur_time[8:3]),
        .time1_i     (cur_time[5:0]),
        
        .rgb_o      (rgb_o)
    );
    
    logic [3:0] capture_counter;
    
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            capture_counter <= '0;
        end else begin
            if (execute_shader) begin
                capture_counter <= capture_counter + 1;
            end
        end
    end

    // Capture output color, after shader has completed

    logic capture;
    assign capture = capture_counter == 0 && execute_shader_d;
    
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            rgb_d <= '0;
        end else begin
            if (capture) begin
                rgb_d <= rgb_o;
            end
            
            // Blanking intervall
            if (hblank || vblank) begin
                rgb_d <= '0;
            end
        end
    end
    
    // Output color
    assign rrggbb_o = rgb_d;
    
    // Delay output signals one cycle
    // to account for rgb_d
    always_ff @(posedge clk_i) begin
        hsync_o         <= hsync;
        vsync_o         <= vsync;
        next_vertical_o <= next_vertical;
        next_frame_o    <= next_frame;
    end

endmodule
