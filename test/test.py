# SPDX-FileCopyrightText: © 2024 Leo Moser <leomoser99@gmail.com>
# SPDX-License-Identifier: Apache-2.0

import os
import random
from PIL import Image, ImageChops
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer, RisingEdge, FallingEdge
from cocotb.regression import TestFactory

from cocotbext.spi import SpiBus, SpiConfig, SpiMaster

# Tiny Shader Settings
NUM_INSTR = 16
SCALE = 2

# VGA Parameters
WIDTH    = 640
HEIGHT   = 480

HFRONT   = 16
HSYNC    = 96
HBACK    = 48

VFRONT   = 10
VSYNC    = 2
VBACK    = 33

POLARITY = 0

os.makedirs('images/', exist_ok=True)

# Reset coroutine
async def reset_dut(rst_ni, duration_ns):
    rst_ni.value = 0
    await Timer(duration_ns, units="ns")
    rst_ni.value = 1
    rst_ni._log.debug("Reset complete")

async def sync_frame(dut):
    if POLARITY:
        await FallingEdge(dut.vsync)
        await FallingEdge(dut.hsync)
    else:
        await RisingEdge(dut.vsync)
        await RisingEdge(dut.hsync)

# Draw the current frame and return it
async def draw_frame(dut, cycles=2):
    screen_x = -HBACK
    screen_y = -VBACK

    #print(dut.timing_hor.counter.value.integer)
    #print(dut.timing_ver.counter.value.integer)
    print(f"line {screen_y}")

    image = Image.new('RGB', (WIDTH, HEIGHT), "black")
    pixels = image.load()

    while (1):
        for i in range(cycles):
            await RisingEdge(dut.clk)
    
        # Expand color data
        r = dut.rrggbb.value[0:1] << 6
        if (r & 1<<6):
            r = r | 0x3F
        g = dut.rrggbb.value[2:3] << 6
        if (g & 1<<6):
            g = g | 0x3F
        b = dut.rrggbb.value[4:5] << 6
        if (b & 1<<6):
            b = b | 0x3F

        # Inside drawing area
        if screen_y >= 0 and screen_y < HEIGHT and screen_x >= 0 and screen_x < WIDTH:
            #print(dut.timing_hor.counter.value.integer)
            #print(dut.timing_ver.counter.value.integer)
            pixels[screen_x, screen_y] = (r, g, b)
        
        # Received hsync
        if (dut.hsync.value == POLARITY):
            if POLARITY:
                await FallingEdge(dut.hsync)
            else:
                await RisingEdge(dut.hsync)

            screen_y += 1
            #print(dut.timing_hor.counter.value.integer)
            #print(dut.timing_ver.counter.value.integer)
            print(f"line {screen_y}")
            screen_x = -HBACK

        # Received vsync
        elif (dut.vsync.value == POLARITY):
            if POLARITY:
                await FallingEdge(dut.vsync)
                await FallingEdge(dut.hsync)
            else:
                await RisingEdge(dut.vsync)
                await RisingEdge(dut.hsync)
            return image
        else:
            screen_x += 1

@cocotb.test()
async def test_vga_default(dut):
    """Draw two frames with the default shader"""

    # Start the clock
    c = Clock(dut.clk, 20, 'ns')
    await cocotb.start(c.start())

    # Assign default values
    dut.ena.value = 1
    dut.pause_execute.value = 0 # run shader
    
    dut.spi_sclk.value = 0
    dut.spi_mosi.value = 0
    #wire spi_miso;
    dut.spi_cs.value = 0

    # Reset
    await reset_dut(dut.rst_n, 50)
    dut._log.info("Reset done")
    
    # Sync to start of frame
    await sync_frame(dut)
    
    # Start thread to draw frame
    task_draw_frame = await cocotb.start(draw_frame(dut))

    image = await task_draw_frame.join()
    image.save(f"images/default.png")
    
    # Start thread to draw frame
    task_draw_frame = await cocotb.start(draw_frame(dut))

    image = await task_draw_frame.join()
    image.save(f"images/default2.png")

    await ClockCycles(dut.clk, 10)

def load_shader(shader_name):
    """Load a shader from a binary text file"""
    shader = []
    
    with open(f'../sw/binary/{shader_name}.bit') as f:
        for line in f.readlines():
            if '//' in line:
                line = line.split('//')[0]
            line = line.replace('_', '')
            line.strip()
            if line:
                shader.append(int(line, 2))
    
    return shader

# TestFactory
async def test_vga_load(dut, shader_name='test7'):
    """Load a shader and draw one frame"""

    # Start the clock
    c = Clock(dut.clk, 10, 'ns')
    await cocotb.start(c.start())
    
    # SPI
    spi_bus = SpiBus.from_prefix(dut, "spi")

    spi_config = SpiConfig(
        word_width = 8,
        sclk_freq  = 2e6,
        cpol       = False,
        cpha       = True,
        msb_first  = True,
        frame_spacing_ns = 500
    )

    spi_master = SpiMaster(spi_bus, spi_config)

    # Assign default values
    dut.ena.value = 1
    dut.pause_execute.value = 1 # pause shader

    # Reset
    await reset_dut(dut.rst_n, 50)
    dut._log.info("Reset done")
    
    # Get shader
    shader = load_shader(shader_name)
    assert(len(shader) == NUM_INSTR)

    # Send new shader instructions
    await spi_master.write(shader, burst=True)
    
    dut.pause_execute.value = 0 # run shader
    
    # Sync to start of frame
    await sync_frame(dut)
    
    # Start thread to draw frame
    task_draw_frame = await cocotb.start(draw_frame(dut))
    image = await task_draw_frame.join()
    image.save(f"images/{shader_name}.png")
    
    # Scale with factor
    gold = Image.open(f'../sw/images/{shader_name}.png')
    gold = gold.resize((gold.width*NUM_INSTR//SCALE, gold.height*NUM_INSTR//SCALE), Image.NEAREST)
    gold.save(f"images/{shader_name}_gold.png")
    
    # Check that images are the same
    diff = ImageChops.difference(image.convert('RGB'), gold.convert('RGB'))
    assert(not diff.getbbox())

    await ClockCycles(dut.clk, 10)

tf = TestFactory(test_function=test_vga_load)
tf.add_option(name='shader_name', optionlist=['test1', 'test2', 'test3', 'test4', 'test5', 'test6', 'test7', 'test8', 'test9', 'test10', 'test12', 'test13'])
tf.generate_tests()

@cocotb.test(skip=os.environ.get('GATES', None) == "yes")
async def test_spi_shader(dut):
    """Write random data into the shader memory"""

    # Start the clock
    c = Clock(dut.clk, 10, 'ns')
    await cocotb.start(c.start())
    
    spi_bus = SpiBus.from_prefix(dut, "spi")

    spi_config = SpiConfig(
        word_width = 8,
        sclk_freq  = 2e6,
        cpol       = False,
        cpha       = True,
        msb_first  = True,
        frame_spacing_ns = 500
    )

    spi_master = SpiMaster(spi_bus, spi_config)

    # Assign default values
    dut.ena.value = 1
    dut.pause_execute.value = 1 # pause shader

    # Reset
    await reset_dut(dut.rst_n, 50)
    dut._log.info("Reset done")
    
    # Send shader instructions
    shader = [0x42]*NUM_INSTR
    await spi_master.write(shader, burst=True)

    # Verify shader was correctly written
    for i in range(NUM_INSTR):
        assert(dut.tt_um_tiny_shader_v2_mole99_inst.tiny_shader_top_inst.shader_memory_inst.memory[i].value == shader[i])

    await ClockCycles(dut.clk, 10)

