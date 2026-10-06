import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


async def tick(dut):
    await FallingEdge(dut.clk)

    # Let nonblocking assignments triggered by the edge settle.
    await Timer(1, unit="ns")


@cocotb.test()
async def test_delay_counter(dut):
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
    dut.dec.value = 0
    dut.data_in.value = 0

    await tick(dut)

    # Check that reset sets the counter to 0.
    assert int(dut.data_out.value) == 0

    # Release reset.
    dut.rst.value = 0

    # No load or decrement: counter should hold.
    await tick(dut)

    assert int(dut.data_out.value) == 0

    # Load an arbitrary value.
    dut.load.value = 1
    dut.data_in.value = 5

    await tick(dut)

    assert int(dut.data_out.value) == 5

    # Load has priority over decrement.
    dut.dec.value = 1
    dut.load.value = 1
    dut.data_in.value = max_value

    await tick(dut)

    assert int(dut.data_out.value) == max_value

    # Stop loading and count down one step.
    dut.load.value = 0
    dut.dec.value = 1

    await tick(dut)

    assert int(dut.data_out.value) == max_value - 1

    # Continue decrementing to zero.
    for expected in range(max_value - 2, -1, -1):
        await tick(dut)
        assert int(dut.data_out.value) == expected

    # At zero, decrement should hold the value at zero.
    await tick(dut)

    assert int(dut.data_out.value) == 0

    # Load a small value and verify a short countdown.
    dut.dec.value = 0
    dut.load.value = 1
    dut.data_in.value = 2

    await tick(dut)

    assert int(dut.data_out.value) == 2

    dut.load.value = 0
    dut.dec.value = 1

    await tick(dut)

    assert int(dut.data_out.value) == 1

    await tick(dut)

    assert int(dut.data_out.value) == 0