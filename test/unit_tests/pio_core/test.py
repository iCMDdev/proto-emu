import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def start_clock(dut):
    cocotb.start_soon(
        # 20 ns = 50 MHz
        Clock(dut.clk, 20, unit="ns").start()
    )


def encode_jmp(cond, addr):
    return (cond << 9) | (addr & 0x1FF)


def encode_set(dst, imm):
    return 0x9000 | ((dst & 0x3) << 8) | (imm & 0xFF)


async def posedge_tick(dut):
    await RisingEdge(dut.clk)

    # Let Verilog nonblocking assignments settle.
    # Also puts us back in a phase where we may drive signals.
    await Timer(1, unit="ns")


@cocotb.test()
async def test_unconditional_jump(dut):
    start_clock(dut)

    # Reset
    dut.rst.value = 1
    dut.instr.value = 0

    await posedge_tick(dut)

    # Check that reset clears X and Y.
    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 0

    # Release reset
    dut.rst.value = 0

    # JMP ALWAYS, address 5
    # 0 | E | S | COND[3:0] | ADDRESS[8:0]
    dut.instr.value = encode_jmp(0, 5)

    await Timer(1, unit="ns")

    # The core only signals whether the jump is taken.
    assert int(dut.branch_taken.value) == 1


@cocotb.test()
async def test_delay_instruction(dut):
    start_clock(dut)

    # Reset
    dut.rst.value = 1
    dut.instr.value = 0

    await posedge_tick(dut)

    # Check that reset clears the delay counter.
    assert int(dut.hold_pipeline.value) == 0

    # Release reset.
    dut.rst.value = 0

    # NOP 0: delay opcode with no extra stall cycles.
    # 1 | 00 | 110 | DELAY[9:0]
    dut.instr.value = 0x9800

    await posedge_tick(dut)
    assert int(dut.hold_pipeline.value) == 0

    # The next instruction should execute immediately.
    dut.instr.value = encode_set(0, 0x11)

    await posedge_tick(dut)
    assert int(dut.x.value) == 0x0011

    # NOP 3: stall for three extra instruction slots after the NOP itself.
    dut.instr.value = 0x9803

    await posedge_tick(dut)
    assert int(dut.hold_pipeline.value) == 1

    # FETCH has already advanced to the NEXT instruction.
    # That instruction must not execute until the delay finishes.
    dut.instr.value = encode_set(0, 0x22)

    for _ in range(3):
        assert int(dut.hold_pipeline.value) == 1

        await posedge_tick(dut)

        # SET X must not execute during the delay.
        assert int(dut.x.value) == 0x0011

    assert int(dut.hold_pipeline.value) == 0

    # NOP 3 takes 4 total cycles.
    # The next instruction can now execute.
    await posedge_tick(dut)
    assert int(dut.x.value) == 0x0022

    # Test consecutive NOP instructions.
    # The second NOP must not reload the counter during the first delay.
    dut.instr.value = 0x9802  # NOP 2

    await posedge_tick(dut)
    assert int(dut.hold_pipeline.value) == 1

    # The NEXT instruction is NOP 3.
    dut.instr.value = 0x9803

    for _ in range(2):
        assert int(dut.hold_pipeline.value) == 1
        await posedge_tick(dut)

    assert int(dut.hold_pipeline.value) == 0

    # Only now should the second NOP load its delay counter.
    await posedge_tick(dut)
    assert int(dut.hold_pipeline.value) == 1

    dut.instr.value = encode_set(1, 0x34)

    for _ in range(3):
        assert int(dut.hold_pipeline.value) == 1

        await posedge_tick(dut)

        assert int(dut.y.value) == 0

    assert int(dut.hold_pipeline.value) == 0

    await posedge_tick(dut)
    assert int(dut.y.value) == 0x0034

    # Once the delay reaches zero, test the maximum-delay NOP.
    # NOP 1023 takes 1024 total cycles
    # (NOP 0 = 1 instruction nop + 0 additional delay;
    #  similarly, NOP x = 1 instruction NOP + x additional delay).
    dut.instr.value = 0x9BFF

    await posedge_tick(dut)
    assert int(dut.hold_pipeline.value) == 1

    # The following instruction must wait for all 1023 extra cycles.
    dut.instr.value = encode_set(1, 0x55)

    for _ in range(1023):
        assert int(dut.hold_pipeline.value) == 1

        await posedge_tick(dut)

        assert int(dut.y.value) == 0x0034

    assert int(dut.hold_pipeline.value) == 0

    # After the full delay has elapsed, the next instruction may execute.
    await posedge_tick(dut)
    assert int(dut.y.value) == 0x0055


@cocotb.test()
async def test_set_x_y(dut):
    start_clock(dut)

    dut.rst.value = 1
    dut.instr.value = 0

    await posedge_tick(dut)

    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 0

    dut.rst.value = 0

    # SET X, 0xAB
    dut.instr.value = encode_set(0, 0xAB)

    await posedge_tick(dut)

    assert int(dut.x.value) == 0x00AB
    assert int(dut.y.value) == 0x0000

    # SET Y, 0x34
    dut.instr.value = encode_set(1, 0x34)

    await posedge_tick(dut)

    assert int(dut.x.value) == 0x00AB
    assert int(dut.y.value) == 0x0034


@cocotb.test()
async def test_conditional_jumps(dut):
    start_clock(dut)

    dut.rst.value = 1
    dut.instr.value = 0

    await posedge_tick(dut)

    assert int(dut.x.value) == 0
    assert int(dut.y.value) == 0

    dut.rst.value = 0

    # Start with X = 1 and Y = 2.
    dut.instr.value = encode_set(0, 0x01)
    await posedge_tick(dut)
    assert int(dut.x.value) == 1

    dut.instr.value = encode_set(1, 0x02)
    await posedge_tick(dut)
    assert int(dut.y.value) == 2

    # JMP X != 0, target 7.
    dut.instr.value = encode_jmp(2, 7)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 1

    # JMP X == 0 should not take while X is still nonzero.
    dut.instr.value = encode_jmp(1, 9)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 0

    # Clear X and check X == 0 does take.
    dut.instr.value = encode_set(0, 0x00)
    await posedge_tick(dut)
    assert int(dut.x.value) == 0

    dut.instr.value = encode_jmp(1, 11)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 1

    # X-- != 0 does not take when X is already zero.
    dut.instr.value = encode_jmp(3, 13)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 0

    await posedge_tick(dut)
    assert int(dut.x.value) == 0x0000

    # Reload X and check X-- != 0 takes and decrements.
    dut.instr.value = encode_set(0, 0x01)
    await posedge_tick(dut)
    assert int(dut.x.value) == 1

    dut.instr.value = encode_jmp(3, 15)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 1

    await posedge_tick(dut)
    assert int(dut.x.value) == 0x0000

    # X must not underflow when already zero.
    assert int(dut.branch_taken.value) == 0

    # Y != 0 takes while Y is nonzero.
    dut.instr.value = encode_jmp(5, 17)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 1

    # Y == 0 does not take while Y is nonzero.
    dut.instr.value = encode_jmp(4, 19)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 0

    # Clear Y, then Y == 0 takes.
    dut.instr.value = encode_set(1, 0x00)
    await posedge_tick(dut)
    assert int(dut.y.value) == 0

    dut.instr.value = encode_jmp(4, 21)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 1

    # Y-- != 0 does not take when Y is zero.
    dut.instr.value = encode_jmp(6, 23)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 0

    await posedge_tick(dut)
    assert int(dut.y.value) == 0x0000

    # Reload Y and check Y-- != 0 takes and decrements.
    dut.instr.value = encode_set(1, 0x02)
    await posedge_tick(dut)
    assert int(dut.y.value) == 2

    dut.instr.value = encode_jmp(6, 25)
    await Timer(1, unit="ns")
    assert int(dut.branch_taken.value) == 1

    await posedge_tick(dut)
    assert int(dut.y.value) == 0x0001