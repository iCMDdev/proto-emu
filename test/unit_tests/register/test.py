import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer
import random

async def tick(dut):
    await FallingEdge(dut.clk)

    # Let nonblocking assignments triggered by the edge settle.
    await Timer(1, unit="ns")


@cocotb.test()
async def test_register(dut):
    # Determine the configured WIDTH from the DUT itself.
    width = len(dut.data_out)
    max_value = (1 << width) - 1

    # 20 ns = 50 MHz
    cocotb.start_soon(
        Clock(dut.clk, 20, unit="ns").start()
    )

    # Reset
    dut.rst.value = 1
    dut.we.value = 0
    dut.data_in.value = 0

    await tick(dut)

    # Check that reset sets register to 0.
    assert int(dut.data_out.value) == 0

    # Release reset.
    dut.rst.value = 0

    # Nothing: register should hold.
    await tick(dut)

    assert int(dut.data_out.value) == 0

    step = max(1, (max_value + 1) // 65535)
    for i in range(0, max_value+1, step):
        # Load an arbitrary value.
        dut.we.value = 1
        dut.data_in.value = i

        await tick(dut)
        assert int(dut.data_out.value) == i

        dut.we.value = 0
        dut.data_in.value = random.randint(0, max_value)

        await tick(dut)
        assert int(dut.data_out.value) == i
