package test

import "core:slice"
import "core:testing"
import "core:math/rand"

import crux "../src"

@(private)
expect_same_retrieval :: proc(t: ^testing.T, buf: ^crux.NetworkBuffer, data: ^[$S]u8) {
    retrieved, err := crux.buf_read_nbytes(buf, len(data))
    defer if err == nil do delete(retrieved)
    testing.expect_value(t, err, crux.ReadError.None)
    testing.expectf(t, slice.equal(data[:], retrieved), "expected data to be equal: %v and %v differ", data, retrieved)
}

// @(test)
test_length_and_offset_correctness :: proc(t: ^testing.T) {
    using crux
    r := create_network_buf()
    defer destroy_network_buf(&r)

    data := random_block(50)
    buf_push_data(&r, data[:])

    testing.expect(t, r.len == len(data))
    testing.expect(t, r.r_offset == 0)

    expect_same_retrieval(t, &r, &data)
}

// @(test)
test_packed_reads_zero_offset :: proc(t: ^testing.T) {
    using crux
    r := create_network_buf()
    defer destroy_network_buf(&r)

    data := random_block(50)
    buf_push_data(&r, data[:])

    expect_same_retrieval(t, &r, &data)
}

// write 20 bytes, then 50, read the 20 back out and assure next read returns 50, subsequent reads fail
@(test)
test_packed_read_non_enclosed_block :: proc(t: ^testing.T) {
    using crux
    r := create_network_buf()
    // defer destroy_network_buf(&r)

    b20: [20]u8
    b50: [50]u8
    // somehow needed or wont segfault
    _ = rand.read(b20[:])
    _ = rand.read(b20[:])
    // b20 := random_block(20)
    // b50 := random_block(50)

    buf_push_data(&r, b20[:])
    buf_push_data(&r, b50[:])

    _, _ = buf_read_nbytes(&r, 20) // alloc
    b2, _ := buf_read_nbytes(&r, 20) // alloc
    // delete(b)
    delete(b2)

    // expect_same_retrieval(t, &r, &b20)
    // expect_same_retrieval(t, &r, &b50)

    // bytes, err := read_nbytes(&r, 1, context.temp_allocator)
    // log.warn(bytes == nil)
    // testing.expect_value(t, len(bytes), 0)
    // testing.expect(t, err == .ShortRead, "expected next read to fail as buf is empty")
}

// @(test)
test_growth :: proc(t: ^testing.T) {
    using crux
    r := create_network_buf(cap=50)
    defer destroy_network_buf(&r)

    data := random_block(50)
    buf_push_data(&r, data[:])
    testing.expect(t, r.len == len(data))
    testing.expect(t, r.r_offset == 0)
    testing.expect(t, cap(r.data) == 50)
}

// @(test)
read_on_empty :: proc(t: ^testing.T) {
    using crux
    r := create_network_buf()
    defer destroy_network_buf(&r)

    bytes, err := buf_read_nbytes(&r, 1, context.temp_allocator)
    testing.expect_value(t, len(bytes), 0)
    testing.expect(t, err == .ShortRead, "expected read to fail as buf is empty")
}

// @(private)
random_block :: proc($Size: int) -> (b: [Size]u8) {
    _ = rand.read(b[:])
    return
}

// @(test)
read_var_ints :: proc(t: ^testing.T) {
    using crux
    test_cases := []TestCase {
        {bytes = {0x00}, expected = VarInt(0)},
        {bytes = {0x01}, expected = VarInt(1)},
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
        buf := create_network_buf()
        defer destroy_network_buf(&buf)

        buf_push_data(&buf, test.bytes)

        initial_off := buf.r_offset
        initial_len := buf.len

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
                t, buf.len == initial_len, "test case %d: length not rolled back (expected %d != %d)",
                i, initial_len, buf.len,
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
