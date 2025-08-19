package test

import "core:slice"
import "core:testing"
import "core:math/rand"

import crux "../src"

@(test)
ensure_readable :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf()

    testing.expect_value(t, buf_ensure_readable(buf, 1), ReadError.ShortRead)

    buf_write_byte(&buf, 1)
    testing.expect_value(t, buf_ensure_readable(buf, 1), ReadError.None)
    testing.expect_value(t, buf_ensure_readable(buf, 5), ReadError.ShortRead)
}

@(test)
length_and_offset_correctness :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf()
    data := random_block(50)
    
    buf_write_bytes(&buf, data[:])
    expect_buf_state(t, buf, length=len(data), r_offset=0)
    expect_same_retrieval(t, &buf, &data)
}

@(test)
packed_reads_zero_offset :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf()
    data := random_block(50)
    
    buf_write_bytes(&buf, data[:])
    expect_same_retrieval(t, &buf, &data)
}

// write 20 bytes, then 50, read the 20 back out and assure next read returns 50, subsequent reads fail
@(test)
packed_read_non_enclosed_block :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf()

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
growth :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf(cap=5)
    data := random_block(50)
    
    buf_write_bytes(&buf, data[:])
    expect_buf_state(t, buf, length=len(data), capacity=50, r_offset=0)
}

@(test)
growth_wrapping :: proc(t: ^testing.T) #no_bounds_check {
    using crux
    // |  5  |     |  4  |   3 |
    // | \\\ |     | /// | /// | ...new allocation | -> move block 3 and 4 to the right
    //  -----W-----R----- -----
    initial_data: [3]u8 = { 4, 3, 5 }
    buf := scoped_create_network_buf(cap=4)

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
    testing.expect_value(t, slice.suffix_length(buf.data[len(buf.data) - 5 /* last 5 */:], []u8 { 12, 12, 12, 4, 3 }), 5)
}

@(test)
read_on_empty :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf()

    err := buf_read_nbytes(&buf, {0})
    testing.expect(t, err == .ShortRead, "expected read to fail as buf is empty")
}

@(test)
write_var_ints :: proc(t: ^testing.T) {
    using crux
    // negative numbers test sign extension
    test_cases: []struct { input: VarInt, expected: []u8 } = {
        { VarInt(-2147483648), {0x80, 0x80, 0x80, 0x80, 0x08} },
        { VarInt(-1), {0xFF, 0xFF, 0xFF, 0xFF, 0x0F} },
        { VarInt(-2), {0xFE, 0xFF, 0xFF, 0xFF, 0x0F} },
        { VarInt(-3), {0xFD, 0xFF, 0xFF, 0xFF, 0x0F} },
        { VarInt(-10), {0xF6, 0xFF, 0xFF, 0xFF, 0x0F} },
        { VarInt(-128), {0x80, 0xff, 0xff, 0xff, 0xf} },
        { VarInt(-255), {0x81, 0xFE, 0xFF, 0xFF, 0xF} },
        { VarInt(-1024), {0x80, 0xF8, 0xFF, 0xFF, 0x0F} },
    }
    
    for test in test_cases {
        buf := scoped_create_network_buf()
        buf_write_var_int(&buf, test.input)
        expect_buf_state(t, buf, raw_data=test.expected)
    }
}

@(test)
read_var_ints :: proc(t: ^testing.T) {
    using crux
    test_cases := []TestCase {
        {bytes = {0xff, 0xff, 0xff, 0xff, 0x0f}, expected = VarInt(-1)},
        {bytes = {0x0b}, expected = VarInt(11)},
        {bytes = {0x7f}, expected = VarInt(127)},
        {bytes = {0x80, 0x01}, expected = VarInt(128)},
        {bytes = {0xff, 0x01}, expected = VarInt(255)},
        {bytes = {0xdd, 0xc7, 0x01}, expected = VarInt(25565)},
        {bytes = {0xff, 0xff, 0x7f}, expected = VarInt(2097151)},
        
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
        {bytes = {0xbd, 0xc5, 0x7}, expected = VarInt(123581)},
        {bytes = {0xff, 0xff, 0x7f}, expected = VarInt(2097151)},
        {bytes = {0xFF, 0xFF, 0xFF, 0xFF, 0x07}, expected = VarInt(2147483647)},
        {bytes = {0x80, 0x80, 0x80, 0x80, 0x08}, expected = VarInt(-2147483648)},

        // Additional single-byte values
        {bytes = {0x03}, expected = VarInt(3)},
        {bytes = {0x0A}, expected = VarInt(10)},
        {bytes = {0x3F}, expected = VarInt(63)},

        // Two-byte values
        {bytes = {0x80, 0x02}, expected = VarInt(256)},
        {bytes = {0xFF, 0x03}, expected = VarInt(511)},

        // Three-byte values
        {bytes = {0x80, 0x80, 0x80, 0x1}, expected = VarInt(2097152)},
        {bytes = {0xff, 0x80, 0x80, 0x1}, expected = VarInt(2097151 + 128)},
        {bytes = {0xea, 0xc7, 0x18}, expected = VarInt(402410)},
        {bytes = {0x80, 0x80, 0x1}, expected = VarInt(16384)},

        // Four-byte values
        {bytes = {0x80, 0x80, 0x80, 0x80, 0x1}, expected = VarInt(268435456)},
        {bytes = {0xff, 0xff, 0xff, 0x7f}, expected = VarInt(268435455)},
        {bytes = {0x9a, 0xa5, 0xab, 0xd}, expected = VarInt(27972250)},

        // Five-byte values
        {bytes = {0xc7, 0xc2, 0xeb, 0xa3, 0x1}, expected = VarInt(343597383)},

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
        buf := scoped_create_network_buf()

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

//  |     |     |     |     |  ->  | /// | /// |     |     |
// RWM----|-----|-----|-----|     RM-----|-----W-----|-----|
@(test)
prepend_var_int_2bytes_empty :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf(cap=4)
    wmark := buf_emit_write_mark(buf)
    werr := buf_write_var_int_at(&buf, wmark, VarInt(128) /* 0x80 0x01 */)
    
    testing.expect_value(t, werr, WriteError.None)
    expect_buf_state(t, buf, length=2, r_offset=0, raw_data=[]u8{ 0x80, 0x01 })
    
    expect_read_result(
        t, buf_read_var_int(&buf),
        VarInt(128), .None,
    )
}

// | /// | /// |
// RM----|-----W
@(test)
prepend_var_int_3bytes_filling_cap :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf(cap=3)
    wmark := buf_emit_write_mark(buf)
    werr := buf_write_var_int_at(&buf, wmark, VarInt(25565) /* 0xDD 0xC7 0x01 */)
    
    testing.expect_value(t, werr, WriteError.None)
    expect_buf_state(t, buf, length=3, capacity=3, r_offset=0)
}

@(test)
prepending_var_int_5bytes_reallocs :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf(cap=3)
    wmark := buf_emit_write_mark(buf)
    werr := buf_write_var_int_at(&buf, wmark, VarInt(-2147483648) /* 0x80 0x80 0x80 0x80 0x08 */)
    
    testing.expect_value(t, werr, WriteError.None)
    expect_buf_state(t, buf, length=5)
    testing.expect(t, cap(buf.data) >= 5, "expected to resize >= 5")
}

// | 0x05 | 0x06 |     |     | ... |  ->  | 0x05 | 0x06 | 0x80 | 0x80 | 0x01 | ... |
// R------|-----WM-----|-----| ... |      R------|------M------|------|------W ... |
@(test)
insert_var_int_3bytes_excess_trailing_space :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf()

    initial := []u8{ 0x05, 0x06 }
    buf_write_bytes(&buf, initial)
    expect_buf_state(t, buf, length=2, r_offset=0, raw_data=initial)

    wmark := buf_emit_write_mark(buf)
    werr := buf_write_var_int_at(&buf, wmark, VarInt(16384) /* 0x80 0x80 0x01 */)

    testing.expect_value(t, werr, WriteError.None)
    expect_buf_state(t, buf, length=5, r_offset=0, raw_data=[]u8{ 0x05, 0x06, 0x80, 0x80, 0x01 })
}

// | 0x12 | 0x48 |     | ... |  ->  | 0x12 | 0xac | 0x02 | 0x48 | ... | 
// R------M------W-----| ... |      R------M------|------|------W ... |
@(test)
insert_var_int_between_existing_data :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf()
    
    buf_write_byte(&buf, 0x12)
    wmark := buf_emit_write_mark(buf)
    buf_write_byte(&buf, 0x48)
    
    expect_buf_state(t, buf, length=2, r_offset=0)
    werr := buf_write_var_int_at(&buf, wmark, VarInt(300) /* 0xAC, 0x02 */)
    
    testing.expect_value(t, werr, WriteError.None)
    expect_buf_state(t, buf, length=4, r_offset=0, raw_data=[]u8{ 0x12, 0xAC, 0x02, 0x48 })
}

@(test)
insert_var_int_5bytes_negative :: proc(t: ^testing.T) {
    using crux
    buf := scoped_create_network_buf()
    
    wmark := buf_emit_write_mark(buf)
    werr := buf_write_var_int_at(&buf, wmark, VarInt(-2147483648))
    
    testing.expect_value(t, werr, WriteError.None)
    expect_buf_state(t, buf, length=5, raw_data=[]u8{ 0x80, 0x80, 0x80, 0x80, 0x08 })
}

@(private)
expect_buf_state :: proc(
    t: ^testing.T,
    buf: crux.NetworkBuffer, 
    length: Maybe(int) = nil,
    capacity: Maybe(int) = nil,
    r_offset: Maybe(int) = nil, 
    raw_data: Maybe([]u8) = nil,
    loc:=#caller_location,
) {
    using crux
    if length, ok := length.?; ok {
        testing.expect_value(t, buf_remaining(buf), length, loc=loc)
    }
    if capacity, ok := capacity.?; ok {
        testing.expect_value(t, cap(buf.data), capacity, loc=loc)
    }
    if r_offset, ok := r_offset.?; ok {
        testing.expect_value(t, buf.r_offset, r_offset, loc=loc)
    }
    if raw_data, ok := raw_data.?; ok {
        testing.expectf(
            t, slice.equal(buf.data[:], raw_data), "raw data does not match expected: %x != %x",
            buf.data, raw_data,
            loc=loc,
        )
    }
}

@(private)
expect_read_result :: proc(t: ^testing.T, res: $R, err: crux.ReadError, expected_res: R, expected_err: crux.ReadError, loc:=#caller_location) {
    testing.expect_value(t, res, expected_res, loc=loc)
    testing.expect_value(t, err, expected_err, loc=loc)
}

@(private)
expect_same_retrieval :: proc(t: ^testing.T, buf: ^crux.NetworkBuffer, data: ^[$S]u8) {
    using crux
    temp: [S]u8
    err := buf_read_nbytes(buf, temp[:])
    testing.expect_value(t, err, ReadError.None)
    testing.expectf(t, slice.equal(data[:], temp[:]), "expected data to be equal: %v and %v differ", data, temp[:])
}

@(private, deferred_out=crux.destroy_network_buf)
scoped_create_network_buf :: proc(cap := 512) -> crux.NetworkBuffer {
    return crux.create_network_buf(cap=cap, allocator=context.allocator)
}

@(private)
random_block :: proc($Size: int) -> (b: [Size]u8) {
    _ = rand.read(b[:])
    return
}
