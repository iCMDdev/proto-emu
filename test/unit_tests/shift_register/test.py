import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


async def tick(dut):
    await FallingEdge(dut.clk)

    # Let nonblocking assignments triggered by the edge settle.
    await Timer(1, unit="ns")


async def reset_dut(dut):
    # Reset
    dut.rst.value = 1
    dut.load.value = 0
    dut.shift.value = 0
    dut.shift_right.value = 0
    dut.shift_count.value = 0
    dut.data_in.value = 0
    dut.shift_in.value = 0

    await tick(dut)

    # Check that reset sets register to 0.
    assert int(dut.data_out.value) == 0

    # Release reset.
    dut.rst.value = 0


async def load_value(dut, value):
    # Load value into shift register.
    dut.load.value = 1
    dut.shift.value = 0
    dut.data_in.value = value

    await tick(dut)

    # Check that value was loaded.
    assert int(dut.data_out.value) == value

    # Release load.
    dut.load.value = 0


async def shift_value(dut, count, shift_right):
    width = len(dut.data_out)

    # Shift count 0 encodes a full-width shift.
    encoded_count = 0 if count == width else count

    # Shift in zeroes.
    dut.shift_in.value = 0

    # Configure shift.
    dut.shift_right.value = shift_right
    dut.shift_count.value = encoded_count
    dut.shift.value = 1

    await tick(dut)

    # Release shift.
    dut.shift.value = 0


@cocotb.test()
async def test_shift_left_one_bit(dut):
    width = len(dut.data_out)
    mask = (1 << width) - 1

    # 20 ns = 50 MHz
    cocotb.start_soon(
        Clock(dut.clk, 20, unit="ns").start()
    )

    await reset_dut(dut)

    # Mask value so that it fits any configured WIDTH.
    value = 0b1011 & mask

    await load_value(dut, value)

    # Shift left by one bit.
    await shift_value(dut, count=1, shift_right=0)

    expected = (value << 1) & mask

    assert int(dut.data_out.value) == expected


@cocotb.test()
async def test_shift_right_one_bit(dut):
    width = len(dut.data_out)
    mask = (1 << width) - 1

    # 20 ns = 50 MHz
    cocotb.start_soon(
        Clock(dut.clk, 20, unit="ns").start()
    )

    await reset_dut(dut)

    # Mask value so that it fits any configured WIDTH.
    value = 0b1011 & mask

    await load_value(dut, value)

    # Shift right by one bit.
    await shift_value(dut, count=1, shift_right=1)

    expected = value >> 1

    assert int(dut.data_out.value) == expected


@cocotb.test()
async def test_shift_left_multiple_bits(dut):
    width = len(dut.data_out)
    mask = (1 << width) - 1

    # 20 ns = 50 MHz
    cocotb.start_soon(
        Clock(dut.clk, 20, unit="ns").start()
    )

    await reset_dut(dut)

    # Mask value so that it fits any configured WIDTH.
    value = 0b1011 & mask

    # Shift by 3 bits when possible.
    # For smaller registers, shift by the full width.
    shift_count = min(3, width)

    await load_value(dut, value)

    # Shift left by multiple bits.
    await shift_value(
        dut,
        count=shift_count,
        shift_right=0
    )

    expected = (value << shift_count) & mask

    assert int(dut.data_out.value) == expected


@cocotb.test()
async def test_shift_right_multiple_bits(dut):
    width = len(dut.data_out)
    mask = (1 << width) - 1

    # 20 ns = 50 MHz
    cocotb.start_soon(
        Clock(dut.clk, 20, unit="ns").start()
    )

    await reset_dut(dut)

    # Mask value so that it fits any configured WIDTH.
    value = 0b11010110 & mask

    # Shift by 3 bits when possible.
    # For smaller registers, shift by the full width.
    shift_count = min(3, width)

    await load_value(dut, value)

    # Shift right by multiple bits.
    await shift_value(
        dut,
        count=shift_count,
        shift_right=1
    )

    expected = value >> shift_count

    assert int(dut.data_out.value) == expected