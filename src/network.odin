package crux

import "core:fmt"
import "core:mem"

import "base:intrinsics"

SEGMENT_BITS :: 0x7F
CONTINUE_BIT :: 0x80
MIN_STRING_LENGTH :: 1
MAX_STRING_LENGTH :: 32767

// Ringbuffer used for storing per client network data, may be dynamically reallocated.
// Not thread-safe.
// NOTE: all reading procs act transactional when returning .ShortRead, thus
// not modifying their inner state when not enough bytes are available.
// All other errors are considered fatal and will modify the state of the buffer.
NetworkBuffer :: struct {
    // len(data) is used instead of storing an additional length field, this stores the amount
    // of bytes used, do _not_ print this data, as it does not offset itself, also bounds checking
    // must be disabled to index into this member.
    data: [dynamic]u8 `fmt:"-"`,
    r_offset: int,
}

create_network_buf :: proc(cap := 512, allocator := context.allocator) -> (buf: NetworkBuffer) {
    assert(cap > 0)
    buf.data = make([dynamic]u8, 0, cap, allocator)
    return
}

destroy_network_buf :: proc(buf: ^NetworkBuffer) {
    delete(buf.data)
}

ReadError :: enum {
    None      = 0,
    ShortRead = 1,
    InvalidData,
}

// Dumps a NetworkBuffer to stdout, for debugging purposes.
buf_dump :: proc(buf: NetworkBuffer) #no_bounds_check {
    fmt.printfln("NetworkBuffer{{len=%d, r_offset=%d, data=%2d}}",
        len(buf.data), buf.r_offset, buf.data[:len(buf.data)],
    )
}

// Returns the number of total bytes in this buffer.
@(require_results)
buf_remaining :: proc(buf: NetworkBuffer) -> int {
    return len(buf.data)
}

// Checks whether `n` bytes are readable, returns .ShortRead if not.
@(require_results)
buf_ensure_readable :: proc(buf: NetworkBuffer, #any_int n: int) -> ReadError {
    assert(n >= 0) // FIXME: can we formally assert this is always the case?
    #assert(ReadError(0) == .None)
    #assert(ReadError(1) == .ShortRead)
    return ReadError(len(buf.data) < n)
}

// Advances `n` bytes
buf_advance_pos_unchecked :: proc(buf: ^NetworkBuffer, n: int) {
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= n
    buf.r_offset = (buf.r_offset + n) % cap(buf.data)
}

// Inserts a VarInt right before the current reading position, making this the first
// item to be read.
buf_prepend_var_int :: proc(buf: ^NetworkBuffer, val: VarInt) #no_bounds_check {
    val := val
    for {
        buf.r_offset = (buf.r_offset - 1 + cap(buf.data)) % cap(buf.data)
        (cast(^mem.Raw_Dynamic_Array)&buf.data).len += 1

        if val & ~VarInt(SEGMENT_BITS) == 0 {
            buf.data[buf.r_offset] = u8(val)
            return
        }
        buf.data[buf.r_offset] = u8(val & SEGMENT_BITS | CONTINUE_BIT)
        val >>= 7
    }
}

// Pushes data into the buffer, resizing if necessary.
// `data` is copied.
buf_write_bytes :: proc(buf: ^NetworkBuffer, data: []u8) #no_bounds_check {
    space := cap(buf.data) - len(buf.data)
    nrequired := len(data)
    if space < nrequired {
        _buf_reserve_exact(buf, len(buf.data) + nrequired)
    }

    alloc_sz := cap(buf.data)
    w_offset := (buf.r_offset + len(buf.data)) % alloc_sz // always rightmost write
    if w_offset + nrequired > alloc_sz {
        n_nowrap := alloc_sz - w_offset
        // limit copy to amount of items that fits without wrapping, and perform another copy
        intrinsics.mem_copy_non_overlapping(raw_data(buf.data[w_offset:]), raw_data(data), n_nowrap)
        intrinsics.mem_copy_non_overlapping(raw_data(buf.data), raw_data(data[n_nowrap:]), nrequired - n_nowrap)
    } else {
        intrinsics.mem_copy_non_overlapping(raw_data(buf.data[w_offset:]), raw_data(data), nrequired)
    }
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len += nrequired
}

buf_write_var_int :: proc(buf: ^NetworkBuffer, val: VarInt) {
    val := val
    for {
        if val & ~VarInt(SEGMENT_BITS) == 0 {
            buf_write_byte(buf, u8(val))
            return
        }
        buf_write_byte(buf, u8(val & SEGMENT_BITS) | CONTINUE_BIT)
        val >>= 7
    }
}

buf_write_byte :: proc(buf: ^NetworkBuffer, b: u8) {
    space := cap(buf.data) - len(buf.data)
    if space == 0 {
        _grow(buf)
    }
    buf.data[buf.r_offset + len(buf.data)] = b
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len += 1
}

// Grows the internal buffer, with at least `additional` bytes
// FIXME: verify this "at least" is correct
@(private="file")
_grow :: proc(buf: ^NetworkBuffer) {
    old_len := len(buf.data)
    new_cap := old_len * 2

    reserve(&buf.data, new_cap)
    // ensure wrapped around data is correctly positioned at the end of the new allocation
    // | \\\ |     | /// | /// | ...new allocation | -> move block 3 and 4
    //  -----W-----R----- -----
    if buf.r_offset + len(buf.data) > old_len {
        to_copy := old_len - buf.r_offset
        intrinsics.mem_copy_non_overlapping(raw_data(buf.data[new_cap-to_copy:]), raw_data(buf.data[buf.r_offset:]), to_copy)
        buf.r_offset += new_cap - old_len
    }
}

// FIXME: handle address decoding
// // FIXME: get rid of allocation, let client handle this
@(require_results)
buf_read_string :: proc(buf: ^NetworkBuffer, allocator: mem.Allocator) -> (s: string, err: ReadError) {
    length := buf_read_var_int(buf) or_return
    if length < MIN_STRING_LENGTH || length > MAX_STRING_LENGTH {
        return s, .InvalidData
    }
    outb := make([]u8, length, allocator)
    buf_read_nbytes(buf, outb) or_return
    return string(outb), .None
}

// We accept a backing type, because sometimes an enum has only a few variants, where the transmission
// type has a far bigger range, and we want to store the enum as the smallest possible type to save space.
buf_read_enum :: proc(buf: ^NetworkBuffer, $E: typeid, $Backing: typeid) -> (E, ReadError)
where
    intrinsics.type_is_enum(E), intrinsics.type_is_numeric(Backing) {
    outb: [size_of(Backing)]u8
    buf_read_nbytes(buf, outb) or_return
    e := transmute(E) outb
    // FIXME: add fast path with type_is_contiguous clause
    for constant in E do if constant == e {
        return e, .None
    }
    return e, .InvalidData
}

// TODO: what even happens on short reads on primitives, we are probably supposed to handle this

@(require_results)
buf_read_int :: proc(buf: ^NetworkBuffer) -> (val: i32be, err: ReadError) {
    buf_ensure_readable(buf^, 4) or_return
    #unroll for _ in 0..=3 {
        // FIXME: optimize to single memcpy
        val = (val << 8) | cast(i32be) buf_unchecked_read_byte(buf)
    }
    return
}

@(require_results)
buf_read_var_int :: proc(buf: ^NetworkBuffer) -> (val: VarInt, err: ReadError) {
    len_mark := len(buf.data)
    r_offset_mark := buf.r_offset
    pos: u16

    for {
        curr, read_err := buf_read_byte(buf)
        if read_err == .ShortRead {
            // fine as long as b.data is left untouched
            (cast(^mem.Raw_Dynamic_Array)&buf.data).len = len_mark
            buf.r_offset = r_offset_mark
            return 0, .ShortRead
        }
        read_err or_return

        val |= auto_cast (curr & SEGMENT_BITS) << pos
        if curr & CONTINUE_BIT == 0 do break

        pos += 7
        if pos >= 32 {
            return 0, .InvalidData // too big
        }
    }
    return val, .None
}

// Outputs:
// `nbytes`: the number of bytes this VarInt uses (continuation byte included)
@(require_results)
buf_peek_var_int :: proc(buf: ^NetworkBuffer) -> (val: VarInt, nbytes: int, err: ReadError) {
    pos: u16

    for {
        curr := buf_peek_byte(buf, pos / 7) or_return
        val |= auto_cast (curr & SEGMENT_BITS) << pos
        pos += 7

        if curr & CONTINUE_BIT == 0 do break

        if pos >= 32 {
            return val, nbytes, .InvalidData // too big
        }
    }
    return val, int(pos / 7), .None
}

@(require_results)
buf_read_var_long :: proc(buf: ^NetworkBuffer) -> (val: VarLong, err: ReadError) {
    len_mark := len(buf.data)
    r_offset_mark := buf.r_offset
    pos: u16

    for {
        curr, read_err := buf_read_byte(buf)
        if read_err == .ShortRead {

            // fine as long as b.data is left untouched
            (cast(^mem.Raw_Dynamic_Array)&buf.data).len = len_mark
            buf.r_offset = r_offset_mark
            return 0, .ShortRead
        }
        val |= auto_cast (curr & SEGMENT_BITS) << pos
        pos += 7

        if curr & CONTINUE_BIT == 0 do break

        if pos >= 64 {
            // too big
            return val, .InvalidData
        }
    }
    return val, .None
}

// Copies `len(outb)` bytes from this buffer into `outb`. `ReadError.ShortRead` is returned
// when not enough bytes are available, the internal state is updated to reflect the consumed bytes.
@(require_results)
buf_read_nbytes :: proc(buf: ^NetworkBuffer, outb: []u8) -> ReadError #no_bounds_check {
    // TODO: when n is zero, return early?
    n := len(outb)
    buf_ensure_readable(buf^, n) or_return

    // bytes copyable from read offset to boundary (array end or length)
    // FIXME: can this be done with less branches?
    n_nowrap := min(n, cap(buf.data) - buf.r_offset, len(buf.data))
    intrinsics.mem_copy_non_overlapping(raw_data(outb), raw_data(buf.data[buf.r_offset:]), n_nowrap)

    if n > n_nowrap {
        intrinsics.mem_copy_non_overlapping(raw_data(outb[n_nowrap:]), raw_data(outb), n - n_nowrap)
    }

    buf.r_offset = (buf.r_offset + n) % cap(buf.data)
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= n
    return .None
}

@(require_results)
buf_read_u16 :: proc(buf: ^NetworkBuffer) -> (u: u16be, err: ReadError) {
    buf_ensure_readable(buf^, 2) or_return
    // FIXME: optimize
    msb := buf_unchecked_read_byte(buf)
    lsb := buf_unchecked_read_byte(buf)
    return u16be(msb) << 8 | u16be(lsb), .None
}

@(require_results)
buf_consume_u16 :: proc(buf: ^NetworkBuffer, u: u16) -> (match: bool, err: ReadError) #no_bounds_check {
    buf_ensure_readable(buf^, 2) or_return
    msb := buf.data[buf.r_offset]
    lsb := buf.data[(buf.r_offset + 1) % cap(buf.data)]
    if (u16(msb) << 8) | u16(lsb) == u {
        (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= 2
        buf.r_offset = (buf.r_offset + 2) % cap(buf.data)
        return true, .None
    }
    return false, .None
}

@(require_results)
buf_consume_byte :: proc(buf: ^NetworkBuffer, expected: u8) -> (match: bool, err: ReadError) #no_bounds_check {
    buf_ensure_readable(buf^, 1) or_return
    if buf.data[buf.r_offset] == expected {
        (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= 1
        buf.r_offset = (buf.r_offset + 1) % cap(buf.data)
        return true, .None
    }
    return false, .None
}

@(require_results)
buf_read_byte :: proc(buf: ^NetworkBuffer) -> (u8, ReadError) #no_bounds_check {
    if len(buf.data) == 0 do return 0, .ShortRead
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= 1
    defer buf.r_offset = (buf.r_offset + 1) % cap(buf.data)
    return buf.data[buf.r_offset], .None
}

@(require_results)
buf_peek_byte :: proc(buf: ^NetworkBuffer, #any_int off := 0) -> (u8, ReadError) #no_bounds_check {
    if len(buf.data) <= off do return 0, .ShortRead
    return buf.data[(buf.r_offset + off) % cap(buf.data)], .None
}

@(require_results)
buf_unchecked_read_byte :: proc(buf: ^NetworkBuffer) -> u8 #no_bounds_check {
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= 1
    defer buf.r_offset = (buf.r_offset + 1) % cap(buf.data)
    return buf.data[buf.r_offset]
}
