package test

import "core:slice"
import "core:testing"
import "core:math/rand"

import crux "../src"

@(private)
expect_same_retrieval :: proc(t: ^testing.T, buf: ^crux.NetworkBuffer, data: ^[$S]u8) {
    temp: [S]u8
    err := crux.buf_read_nbytes(buf, temp[:])
    testing.expect_value(t, err, crux.ReadError.None)
    testing.expectf(t, slice.equal(data[:], temp[:]), "expected data to be equal: %v and %v differ", data, temp[:])
}

@(test)
test_length_and_offset_correctness :: proc(t: ^testing.T) {
    using crux
    buf := create_network_buf(allocator=context.allocator)
    defer destroy_network_buf(buf)

    data := random_block(50)
    buf_write_bytes(&buf, data[:])

    testing.expect(t, buf_remaining(buf) == len(data))
    testing.expect(t, buf.r_offset == 0)

    expect_same_retrieval(t, &buf, &data)
}

@(test)
test_packed_reads_zero_offset :: proc(t: ^testing.T) {
    using crux
    buf := create_network_buf(allocator=context.allocator)
    defer destroy_network_buf(buf)

    data := random_block(50)
    buf_write_bytes(&buf, data[:])

    expect_same_retrieval(t, &buf, &data)
}

// write 20 bytes, then 50, read the 20 back out and assure next read returns 50, subsequent reads fail
@(test)
test_packed_read_non_enclosed_block :: proc(t: ^testing.T) {
    using crux
    buf := create_network_buf(allocator=context.allocator)
    defer destroy_network_buf(buf)

    b20 := random_block(20)
    b50 := random_block(50)

    buf_write_bytes(&buf, b20[:])
    buf_write_bytes(&buf, b50[:])

    expect_same_retrieval(t, &buf, &b20)
    expect_same_retrieval(t, &buf, &b50)

    err := buf_read_nbytes(&buf, {0})
    testing.expect(t, err == .ShortRead, "expected next read to fail as buf is empty")
}

@(test)
test_growth :: proc(t: ^testing.T) {
    using crux
    buf := create_network_buf(cap=5, allocator=context.allocator)
    defer destroy_network_buf(buf)

    data := random_block(50)
    buf_write_bytes(&buf, data[:])

    testing.expect(t, buf_remaining(buf) == len(data))
    testing.expect(t, buf.r_offset == 0)
    testing.expect(t, cap(buf.data) == 50)
}

@(test)
test_growth_wrapping :: proc(t: ^testing.T) #no_bounds_check {
    using crux
    // |  5  |     |  4  |   3 |
    // | \\\ |     | /// | /// | ...new allocation | -> move block 3 and 4 to the right
    //  -----W-----R----- -----
    initial_data: [3]u8 = { 4, 3, 5 }
    buf := create_network_buf(cap=4, allocator=context.allocator)
    defer destroy_network_buf(buf)

    // create initial situation
    buf.r_offset = 2
    buf_write_bytes(&buf, initial_data[:])
    testing.expect_value(t, buf.r_offset, 2)
    testing.expect(t, slice.equal(buf.data[:4], []u8{ 5, 0, 4, 3 }))

    // write more bytes and verify the correct layout
    incoming: [50]u8 = 12
    buf_write_bytes(&buf, incoming[:])

    testing.expect(t, len(buf.data) == 3 + 50, "no proper resize")
    // test beginning, ending contents (5, 12, 12, 12, 12, 12, ..., 4, 3)
    testing.expect_value(t, slice.prefix_length(buf.data[:], []u8{ 5, 12, 12, /* .. */ }), 3)
    testing.expect_value(t, suffix_length(buf.data[len(buf.data) - 5 /* last 5 */:], []u8 { 12, 12, 12, 4, 3 }), 5)
}

@(test)
read_on_empty :: proc(t: ^testing.T) {
    using crux
    buf := create_network_buf(allocator=context.allocator)
    defer destroy_network_buf(buf)

    err := buf_read_nbytes(&buf, {0})
    testing.expect(t, err == .ShortRead, "expected read to fail as buf is empty")
}

@(private)
suffix_length :: proc(a, b: $T/[]$E) -> (n: int) {
    l := min(len(a), len(b))
    for i := l - 1; i >= 0 && a[i] == b[i]; i -= 1 {
        n += 1
    }
    return
}

@(private)
random_block :: proc($Size: int) -> (b: [Size]u8) {
    _ = rand.read(b[:])
    return
}

@(test)
read_var_ints :: proc(t: ^testing.T) {
    using crux
    test_cases := []TestCase {
        {bytes = {0x00}, expected = VarInt(0)},
        {bytes = {0x00, 0x00, 0x00}, expected = VarInt(0)},
        {bytes = {0x01}, expected = VarInt(1)},
        // unnecessarily long encoding
        {bytes = {0x81, 0x00}, expected = VarInt(1)},
        {bytes = {0x02}, expected = VarInt(2)},
        {bytes = {0x7F}, expected = VarInt(127)},
        {bytes = {0x80, 0x01}, expected = VarInt(128)},
        {bytes = {0xFF, 0x01}, expected = VarInt(255)},
        {bytes = {0xAB, 0x04}, expected = VarInt(555)},
        // {bytes = {0xDD, 0xEC, 0x07}, expected = VarInt(123581)},
        // {bytes = {0xFF, 0xFF, 0x3F}, expected = VarInt(2097151)},
        {bytes = {0xFF, 0xFF, 0xFF, 0xFF, 0x07}, expected = VarInt(2147483647)},
        {bytes = {0x80, 0x80, 0x80, 0x80, 0x08}, expected = VarInt(-2147483648)},

        // Additional single-byte values
        {bytes = {0x03}, expected = VarInt(3)},
        {bytes = {0x0A}, expected = VarInt(10)},
        {bytes = {0x3F}, expected = VarInt(63)},

        // Two-byte values
        {bytes = {0x80, 0x02}, expected = VarInt(256)},
        {bytes = {0xFF, 0x03}, expected = VarInt(511)},
        // {bytes = {0x80, 0x80}, expected = VarInt(16384)},

        // Three-byte values
        // {bytes = {0x80, 0x80, 0x01}, expected = VarInt(2097152)},
        // {bytes = {0xFF, 0xFF, 0x01}, expected = VarInt(2097151 + 128)},
        // {bytes = {0xAA, 0xBB, 0x0C}, expected = VarInt(402410)},

        // Four-byte values
        // {bytes = {0x80, 0x80, 0x80, 0x01}, expected = VarInt(268435456)},
        // {bytes = {0xFF, 0xFF, 0xFF, 0x0F}, expected = VarInt(268435455)},
        // {bytes = {0xAA, 0xBB, 0xCC, 0x0D}, expected = VarInt(27972250)},

        // Five-byte values
        // {bytes = {0x80, 0x80, 0x80, 0x80, 0x01}, expected = VarInt(34359738368), error = .None},
        // {bytes = {0xFF, 0xFF, 0xFF, 0xFF, 0x03}, expected = VarInt(4294967295), error = .None},

        // Error cases: Short reads
        {bytes = {}, error = .ShortRead}, // Empty buffer
        {bytes = {0x80}, error = .ShortRead}, // Incomplete 2-byte VarInt
        {bytes = {0x80, 0x80}, error = .ShortRead}, // Incomplete 3-byte VarInt
        {bytes = {0x80, 0x80, 0x80}, error = .ShortRead}, // Incomplete 4-byte VarInt
        {bytes = {0x80, 0x80, 0x80, 0x80}, error = .ShortRead}, // Incomplete 5-byte VarInt

        // Error case: VarInt too large (more than 5 bytes)
        {bytes = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF}, error = .InvalidData},
    }

    for test, i in test_cases {
        buf := create_network_buf(allocator=context.allocator)
        defer destroy_network_buf(buf)

        buf_write_bytes(&buf, test.bytes)

        initial_off := buf.r_offset
        initial_len := buf_remaining(buf)

        value, err := buf_read_var_int(&buf)

        testing.expectf(
            t, err == test.error, "test case %d: difference in expected error (expected %s != %s)",
            i, test.error, err,
        )

        // on short read, verify read was rollbacked
        if test.error == .ShortRead {
            testing.expectf(
                t, buf.r_offset == initial_off, "test case %d: read offset not rolled back (expected %d != %d)",
                i, initial_off, buf.r_offset,
            )
            testing.expectf(
                t, buf_remaining(buf) == initial_len, "test case %d: length not rolled back (expected %d != %d)",
                i, initial_len, buf_remaining(buf),
            )
            continue
        }

        testing.expectf(
            t, value == test.expected, "test case %d: difference in expected value (expected %d != %d)",
            i, test.expected, value,
        )
    }
}

@(private)
TestCase :: struct {
    bytes: []u8,
    expected: crux.VarInt,
    error: crux.ReadError,
}

@(test)
test_prepend_var_int_empty :: proc(t: ^testing.T) {
    using crux
    buf: NetworkBuffer

}
