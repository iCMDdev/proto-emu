import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


async def tick(dut):
    await FallingEdge(dut.clk)

    # Let nonblocking assignments triggered by the edge settle.
    await Timer(1, unit="ns")


@cocotb.test()
async def test_pc_register(dut):
    # Determine the configured WIDTH from the DUT itself.
    width = len(dut.data_out)
    max_value = (1 << width) - 1

    # 20 ns = 50 MHz
    cocotb.start_soon(
        Clock(dut.clk, 20, unit="ns").start()
    )

    # Reset
    dut.rst.value = 1
    dut.load.value = 0
    dut.inc.value = 0
    dut.data_in.value = 0

    await tick(dut)

    # Check that reset sets PC to 0.
    assert int(dut.data_out.value) == 0

    # Release reset.
    dut.rst.value = 0

    # No load or increment: PC should hold.
    await tick(dut)

    assert int(dut.data_out.value) == 0

    # Increment PC.
    dut.inc.value = 1

    await tick(dut)

    assert int(dut.data_out.value) == 1

    # Load an arbitrary value.
    dut.inc.value = 0
    dut.load.value = 1
    dut.data_in.value = 5

    await tick(dut)

    assert int(dut.data_out.value) == 5

    # Load has priority over increment.
    dut.load.value = 1
    dut.inc.value = 1
    dut.data_in.value = max_value

    await tick(dut)

    assert int(dut.data_out.value) == max_value

    # Stop loading; increment maximum value and verify wraparound.
    dut.load.value = 0
    dut.inc.value = 1

    await tick(dut)

    assert int(dut.data_out.value) == 0