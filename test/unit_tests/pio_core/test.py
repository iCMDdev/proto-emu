import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


def start_clock(dut):
    cocotb.start_soon(
        # 20 ns = 50 MHz
        Clock(dut.clk, 20, unit="ns").start()
    )


def encode_jmp(cond, addr):
    return (cond << 9) | (addr & 0x1FF)


def encode_set(dst, imm):
    return 0x9000 | ((dst & 0x3) << 8) | (imm & 0xFF)


async def negedge_tick(dut):
    await FallingEdge(dut.clk)

    # Let Verilog nonblocking assignments settle.
    # Also puts us back in a phase where we may drive signals.
    await Timer(1, unit="ns")


@cocotb.test()
async def test_unconditional_jump(dut):
    start_clock(dut)

    # Reset
    dut.rst.value = 1
    dut.instr.value = 0

    await negedge_tick(dut)

    # Check that reset sets pc to 0    
    assert int(dut.pc.value) == 0

    # Release reset
    dut.rst.value = 0

    # JMP ALWAYS, address 5
    # 0 | E | S | COND[3:0] | ADDRESS[8:0]
    dut.instr.value = encode_jmp(0, 5)

    await negedge_tick(dut)

    assert int(dut.pc.value) == 5


@cocotb.test()
async def test_delay_instruction(dut):
    start_clock(dut)

    # Reset
    dut.rst.value = 1
    dut.instr.value = 0

    await negedge_tick(dut)

    # Check that reset sets pc to 0.
    assert int(dut.pc.value) == 0

    # Release reset.
    dut.rst.value = 0

    # NOP 0: delay opcode with no extra stall cycles.
    # 1 | 00 | 110 | DELAY[9:0]
    dut.instr.value = 0x9800

    await negedge_tick(dut)
    assert int(dut.pc.value) == 1

    await negedge_tick(dut)
    assert int(dut.pc.value) == 2

    # NOP 3: stall for three extra instruction slots after the NOP itself.
    dut.instr.value = 0x9803

    await negedge_tick(dut)
    assert int(dut.pc.value) == 3

    # Keep the delay instruction active while the counter counts down.
    await negedge_tick(dut)
    assert int(dut.pc.value) == 3

    await negedge_tick(dut)
    assert int(dut.pc.value) == 3

    await negedge_tick(dut)
    assert int(dut.pc.value) == 3

    # Once the delay reaches zero, test the maximum-delay NOP.
    # NOP 1023 takes 1024 total cycles
    # (NOP 0 = 1 instruction nop + 0 additional delay;
    #  similarly, NOP x = 1 instruction NOP + x additional delay).
    dut.instr.value = 0x9BFF

    await negedge_tick(dut)
    assert int(dut.pc.value) == 4

    # Hold the maximum-delay NOP across the remaining 1023 cycles.
    for _ in range(1023):
        await negedge_tick(dut)
        assert int(dut.pc.value) == 4

    # After the full delay has elapsed, the next instruction may execute.
    dut.instr.value = 0x8000

    await negedge_tick(dut)
    assert int(dut.pc.value) == 5


@cocotb.test()
async def test_set_x_y(dut):
    start_clock(dut)

    dut.rst.value = 1
    dut.instr.value = 0

    await negedge_tick(dut)
    assert int(dut.pc.value) == 0

    dut.rst.value = 0

    # SET X, 0xAB
    dut.instr.value = encode_set(0, 0xAB)

    await negedge_tick(dut)

    assert int(dut.pc.value) == 1
    assert int(dut.x.value) == 0x00AB
    assert int(dut.y.value) == 0x0000

    # SET Y, 0x34
    dut.instr.value = encode_set(1, 0x34)

    await negedge_tick(dut)

    assert int(dut.pc.value) == 2
    assert int(dut.x.value) == 0x00AB
    assert int(dut.y.value) == 0x0034


@cocotb.test()
async def test_conditional_jumps(dut):
    start_clock(dut)

    dut.rst.value = 1
    dut.instr.value = 0

    await negedge_tick(dut)
    assert int(dut.pc.value) == 0

    dut.rst.value = 0

    # Start with X = 1 and Y = 2.
    dut.instr.value = encode_set(0, 0x01)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 1

    dut.instr.value = encode_set(1, 0x02)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 2

    # JMP X != 0, target 7.
    dut.instr.value = encode_jmp(2, 7)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 7

    # JMP X == 0 should not take while X is still nonzero.
    dut.instr.value = encode_jmp(1, 9)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 8

    # Clear X and check X == 0 does take.
    dut.instr.value = encode_set(0, 0x00)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 9

    dut.instr.value = encode_jmp(1, 11)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 11

    # X-- != 0 does not take when X is already zero.
    dut.instr.value = encode_jmp(3, 13)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 12
    assert int(dut.x.value) == 0x0000

    # Reload X and check X-- != 0 takes and decrements.
    dut.instr.value = encode_set(0, 0x01)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 13

    dut.instr.value = encode_jmp(3, 15)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 15
    assert int(dut.x.value) == 0x0000

    # Y != 0 takes while Y is nonzero.
    dut.instr.value = encode_jmp(5, 17)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 17

    # Y == 0 does not take while Y is nonzero.
    dut.instr.value = encode_jmp(4, 19)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 18

    # Clear Y, then Y == 0 takes.
    dut.instr.value = encode_set(1, 0x00)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 19

    dut.instr.value = encode_jmp(4, 21)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 21

    # Y-- != 0 does not take when Y is zero.
    dut.instr.value = encode_jmp(6, 23)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 22
    assert int(dut.y.value) == 0x0000

    # Reload Y and check Y-- != 0 takes and decrements.
    dut.instr.value = encode_set(1, 0x02)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 23

    dut.instr.value = encode_jmp(6, 25)
    await negedge_tick(dut)
    assert int(dut.pc.value) == 25
    assert int(dut.y.value) == 0x0001