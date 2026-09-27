import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


async def negedge_tick(dut):
    await FallingEdge(dut.clk)

    # Let Verilog nonblocking assignments settle.
    # Also puts us back in a phase where we may drive signals.
    await Timer(1, unit="ns")


@cocotb.test()
async def test_unconditional_jump(dut):
    cocotb.start_soon(
        # 20 ns = 50 MHz
        Clock(dut.clk, 20, unit="ns").start()
    )

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
    dut.instr.value = 5 # 0b0_0_0_0000_000000101

    await negedge_tick(dut)

    assert int(dut.pc.value) == 5