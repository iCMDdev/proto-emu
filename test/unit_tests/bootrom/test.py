import cocotb
from cocotb.triggers import Timer


async def settle():
    await Timer(1, unit="ns")


def read(signal):
    return int(signal.value)


async def edge(dut):
    dut.clk.value = 0
    await Timer(5, unit="ns")
    dut.clk.value = 1
    await Timer(5, unit="ns")


async def reset(dut):
    # Assert reset *without* requiring a rising clock edge.
    dut.clk.value = 0
    dut.rst.value = 0
    dut.branch_taken.value = 0
    dut.hold_pipeline.value = 0
    dut.switch_to_sramland.value = 0
    await settle()
    dut.rst.value = 1
    await settle()

    assert read(dut.pc) == 0
    assert read(dut.boot_from_rom) == 1
    # Check that the ROM has a resolved 16-bit output.
    # this could be anything, for now - i.e. BotROM agnostic,
    # before implementing a full ROM program.
    read(dut.instruction)

    dut.rst.value = 0
    await settle()
    assert read(dut.pc) == 0
    assert read(dut.boot_from_rom) == 1


@cocotb.test()
async def first_instruction_and_sequential_pc(dut):
    """Instruction 0 is ready before the first active rising edge."""
    await reset(dut)

    first_instruction = read(dut.instruction)
    await settle()
    assert read(dut.instruction) == first_instruction

    await edge(dut)
    assert read(dut.pc) == 1
    # assuming the ROM is not 1 instruction only (and it clearly
    # shouldn't), we should still boot from ROM
    # but note: in this test, we deliberately force branch_taken = false.
    assert read(dut.boot_from_rom) == 1 
    read(dut.instruction)

    for expected_pc in range(2, 16):
        await edge(dut)
        assert read(dut.pc) == expected_pc
        assert read(dut.boot_from_rom) == 1
        read(dut.instruction)


@cocotb.test()
async def taken_branch_uses_instruction_address(dut):
    """Taken branches load the low nine bits of the current ROM instruction."""
    await reset(dut)

    # Controls are driven by a real pio_core in TOP, here we're simulating.
    for step in range(40):
        current_pc = read(dut.pc)
        current_instr = read(dut.instruction)
        take_branch = (step % 3 != 1)
        # force take branch / don't take branch, independent of the
        # actual instruction
        dut.branch_taken.value = int(take_branch)
        await settle()

        expected_pc = ((current_instr & 0x1FF) if take_branch
                       else ((current_pc + 1) & 0x1FF))
        await edge(dut)
        assert read(dut.pc) == expected_pc, (
            f"step={step}, instr=0x{current_instr:04x}, "
            f"branch={take_branch}, expected_pc={expected_pc}"
        )
        assert read(dut.boot_from_rom) == 1 # still in ROM


@cocotb.test()
async def hold_freezes_pc_and_instruction(dut):
    """A hold prevents PC movement regardless of branch_taken."""
    await reset(dut)
    for _ in range(4):
        await edge(dut)

    held_pc = read(dut.pc)
    held_instruction = read(dut.instruction)
    dut.hold_pipeline.value = 1
    dut.branch_taken.value = 1
    await settle()

    for _ in range(6):
        await edge(dut)
        assert read(dut.pc) == held_pc
        assert read(dut.instruction) == held_instruction

    dut.hold_pipeline.value = 0
    dut.branch_taken.value = 0
    await settle()
    await edge(dut)
    assert read(dut.pc) == ((held_pc + 1) & 0x1FF)


@cocotb.test()
async def switch_stops_rom_and_reset_restarts(dut):
    """Switch freezes ROM PC and mode stays SRAM until reset."""
    await reset(dut)
    for _ in range(3):
        await edge(dut)
    stopped_pc = read(dut.pc)
    stopped_instruction = read(dut.instruction)

    dut.switch_to_sramland.value = 1
    await settle()
    await edge(dut)
    assert read(dut.boot_from_rom) == 0
    assert read(dut.pc) == stopped_pc
    assert read(dut.instruction) == stopped_instruction

    dut.switch_to_sramland.value = 0
    dut.branch_taken.value = 1
    await settle()
    for _ in range(5):
        await edge(dut)
        assert read(dut.boot_from_rom) == 0
        assert read(dut.pc) == stopped_pc
        assert read(dut.instruction) == stopped_instruction

    # No active clock edge is required to restart BootROM.
    dut.clk.value = 0
    await settle()
    dut.rst.value = 1
    await settle()
    assert read(dut.boot_from_rom) == 1
    assert read(dut.pc) == 0
    read(dut.instruction)


@cocotb.test()
async def switch_has_priority_over_hold(dut):
    """Document mode-register priority if both inputs are asserted."""
    await reset(dut)
    dut.hold_pipeline.value = 1
    dut.switch_to_sramland.value = 1
    await settle()
    await edge(dut)
    assert read(dut.boot_from_rom) == 0
    assert read(dut.pc) == 0


@cocotb.test()
async def sequential_pc_wraps_at_512(dut):
    """The 9-bit PC wraps independently of ROM instructions."""
    await reset(dut)
    for expected_pc in list(range(1, 512)) + [0, 1]:
        await edge(dut)
        assert read(dut.pc) == expected_pc
    assert read(dut.boot_from_rom) == 1
