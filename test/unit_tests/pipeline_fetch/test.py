import cocotb
from cocotb.triggers import Timer


async def settle():
    await Timer(1, unit="ns")


def value(signal):
    return int(signal.value)

# A simple SRAM model
class SyncSram:
    def __init__(self, dut, program):
        self.dut = dut
        self.program = program # program should be a a dict with key = address.
        self.mask = (1 << len(dut.sram_address_a)) - 1 # mask for encoded immediate addrs when branching

    async def edge(self):
        dut = self.dut
        dut.clk.value = 0
        await Timer(5, unit="ns")
        # Port addresses are sampled at the rising edge.
        a = value(dut.sram_address_a)
        b = value(dut.sram_address_b)
        dut.clk.value = 1
        await Timer(2, unit="ns")
        # Model the SRAM clock-to-output delay. New DOUT cannot affect the
        # FETCH instruction FF on the rising edge that initiated this read.
        dut.sram_instr_a.value = self.program.get(a & self.mask, 0x9000)
        dut.sram_instr_b.value = self.program.get(b & self.mask, 0x9000)
        await Timer(3, unit="ns")
        return a, b


async def reset(dut, program):
    dut.clk.value = 0
    dut.rst.value = 1
    dut.boot_from_rom.value = 1
    dut.switch_to_sramland.value = 0
    dut.branch_taken.value = 0
    dut.hold_pipeline.value = 0
    dut.sram_instr_a.value = 0x9000
    dut.sram_instr_b.value = 0x9000
    await settle()
    sram = SyncSram(dut, program)
    assert value(dut.sram_address_a) == 0
    assert value(dut.sram_address_b) == 0
    await sram.edge()
    assert value(dut.instruction) == 0
    dut.rst.value = 0
    await settle()
    return sram


async def handoff(dut, sram):
    # During boot, port A keeps SRAM[0] prefetched.
    for _ in range(2):
        assert value(dut.sram_address_a) == 0
        assert value(dut.sram_address_b) == 0
        await sram.edge()
        assert value(dut.instruction) == 0

    # SRAMLAND switch: FETCH must capture SRAM[0].
    dut.switch_to_sramland.value = 1
    await settle()
    assert value(dut.sram_address_a) == 1
    assert value(dut.sram_address_b) == (sram.program[0] & sram.mask)
    a, b = await sram.edge()
    assert (a, b) == (1, sram.program[0] & sram.mask)
    assert value(dut.instruction) == sram.program[0]
    assert value(dut.fetched_pc_a) == 1
    assert value(dut.fetched_pc_b) == b

    # In the integrated design boot_from_rom is changed by bootrom's FF at
    # the same handoff edge. We're copying that behavior here.
    dut.boot_from_rom.value = 0
    dut.switch_to_sramland.value = 0
    await settle()


@cocotb.test()
async def boot_prefetch_and_back_to_back_taken_branches(dut):
    program = {
        0: 0x0005,     # JMP 5
        1: 0x9001,     # SET X, 1 (not selected)
        5: 0x0009,     # JMP 9
        6: 0x9006,     # SET X, 6 (not selected)
        9: 0x9107,     # SET Y, 7
        10: 0x900A,
    }
    sram = await reset(dut, program)
    await handoff(dut, sram)

    # SRAM[0] JMP 5, branch taken: selects B=SRAM[5].
    dut.branch_taken.value = 1
    await settle()
    assert value(dut.sram_address_a) == 6
    assert value(dut.sram_address_b) == 9
    await sram.edge()
    assert value(dut.instruction) == program[5]
    assert value(dut.fetched_pc_a) == 6
    assert value(dut.fetched_pc_b) == 9

    # SRAM[5] JMP 9, branch taken in the *very next* cycle.
    await sram.edge()
    assert value(dut.instruction) == program[9]
    assert value(dut.fetched_pc_a) == 10
    assert value(dut.fetched_pc_b) == (program[9] & sram.mask)

    # Now the current instruction is SET; its branch is not taken.
    dut.branch_taken.value = 0
    await settle()
    await sram.edge()
    assert value(dut.instruction) == program[10]


@cocotb.test()
async def not_taken_then_hold_and_resume(dut):
    program = {
        0: 0x0005,     # JMP 5 (test forces not-taken)
        1: 0x9101,     # SET Y, 1
        2: 0x9002,     # SET X, 2
        5: 0x9005,
    }
    sram = await reset(dut, program)
    await handoff(dut, sram)

    # Not taken from SRAM[0] -> selects port A (SRAM[1]).
    dut.branch_taken.value = 0
    await settle()
    await sram.edge()
    assert value(dut.instruction) == program[1]

    # hold pipeline
    old_instr = value(dut.instruction)
    old_pc_a = value(dut.fetched_pc_a)
    old_pc_b = value(dut.fetched_pc_b)
    dut.hold_pipeline.value = 1
    await settle()
    for _ in range(4):
        assert value(dut.sram_address_a) == old_pc_a
        assert value(dut.sram_address_b) == old_pc_b
        await sram.edge()
        assert value(dut.instruction) == old_instr
        assert value(dut.fetched_pc_a) == old_pc_a
        assert value(dut.fetched_pc_b) == old_pc_b

    dut.hold_pipeline.value = 0
    await settle()
    await sram.edge()
    assert value(dut.instruction) == program[2]


@cocotb.test()
async def branch_target_and_pc_wraparound(dut):
    program = {
        0: 0x01FF,     # JMP 511
        1: 0x9001,
        511: 0x9007,   # SET X, 7; its sequential successor wraps to 0
    }
    sram = await reset(dut, program)
    await handoff(dut, sram)
    assert value(dut.fetched_pc_b) == 511

    # wraparound is expected
    dut.branch_taken.value = 1
    await settle()
    assert value(dut.sram_address_a) == 0  # 511 + 1 wraps to 0
    await sram.edge()
    assert value(dut.instruction) == program[511]
    assert value(dut.fetched_pc_a) == 0

    # Reset takes priority over both speculative addresses and instruction.
    dut.rst.value = 1
    await settle()
    assert value(dut.sram_address_a) == 0
    assert value(dut.sram_address_b) == 0
    await sram.edge()
    assert value(dut.instruction) == 0
    assert value(dut.fetched_pc_a) == 0
    assert value(dut.fetched_pc_b) == 0
