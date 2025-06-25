package crux

import "core:fmt"
import "core:mem"

import "base:intrinsics"

SEGMENT_BITS :: 0x7F
CONTINUE_BIT :: 0x80

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

/// Dumps a NetworkBuffer to stdout.
dump_network_buffer :: proc(b: NetworkBuffer) #no_bounds_check {
    length := len(b.data)
    fmt.printfln("NetworkBuffer{{len=%d, r_offset=%d, data=%2x}}",
        length, b.r_offset, b.data[b.r_offset:][:length],
    )
}

ReadError :: enum {
    None      = 0,
    ShortRead = 1,
    InvalidData,
}

create_network_buf :: proc(cap := 512, allocator := context.allocator) -> (reader: NetworkBuffer) {
    assert(cap > 0)
    reader.data = make([dynamic]u8, 0, cap, allocator)
    return
}

destroy_network_buf :: proc(b: ^NetworkBuffer) {
    delete(b.data)
}

// Pushes data into the buffer, reallocating if necessary.
// `data` is copied.
push_data :: proc(b: ^NetworkBuffer, data: []u8) #no_bounds_check {
    space := cap(b.data) - len(b.data)
    nrequired := len(data)
    if space < nrequired {
        grow(b, additional=nrequired)
    }

    alloc_sz := cap(b.data)
    insert_from := (b.r_offset + len(b.data)) % alloc_sz // always rightmost write
    if insert_from + nrequired > alloc_sz {
        n_nowrap := alloc_sz - insert_from
        // limit copy to amount of items that fits without wrapping, and perform another copy
        intrinsics.mem_copy_non_overlapping(raw_data(b.data[insert_from:]), raw_data(data), n_nowrap)
        intrinsics.mem_copy_non_overlapping(raw_data(b.data), raw_data(data[n_nowrap:]), nrequired - n_nowrap)
    } else {
        intrinsics.mem_copy_non_overlapping(raw_data(b.data[insert_from:]), raw_data(data), nrequired)
    }
    (cast(^mem.Raw_Dynamic_Array)&b.data).len += nrequired
}

// Grows the internal buffer, with at least `additional` bytes
// FIXME: verify this "at least" is correct
@(private="file")
grow :: proc(b: ^NetworkBuffer, additional: int) {
    old_len := len(b.data)
    when ODIN_DEBUG do assert(old_len > 0)
    new_cap := max(old_len * 2, old_len + additional)

    reserve(&b.data, new_cap)
    // ensure wrapped around data is correctly positioned at the end of the new allocation
    // | \\\ |     | /// | /// | ...new allocation | -> move block 3 and 4
    //  -----W-----R----- -----
    if b.r_offset + len(b.data) > old_len {
        to_copy := old_len - b.r_offset
        copy(b.data[new_cap-to_copy:], b.data[b.r_offset:][:to_copy])
        b.r_offset += new_cap - old_len
    }
}

// FIXME: handle address decoding
// TODO: add max
@(require_results)
read_string :: proc(b: ^NetworkBuffer, allocator: mem.Allocator) -> (s: String, err: ReadError) {
    length := read_var_int(b) or_return
    data := read_nbytes(b, length, allocator) or_return
    return String { length, data }, .None
}

// TODO: what even happens on short reads on primitives, we are probably supposed to handle this

@(require_results)
read_int :: proc(b: ^NetworkBuffer) -> (val: i32be, err: ReadError) {
    ensure_readable(b^, 4) or_return
    #unroll for _ in 0..=3 {
        val = (val << 8) | cast(i32be) unchecked_read_byte(b)
    }
    return
}

@(require_results)
read_var_int :: proc(b: ^NetworkBuffer) -> (val: VarInt, err: ReadError) {
    len_mark := len(b.data)
    r_offset_mark := b.r_offset
    pos: u16

    for {
        curr, read_err := read_byte(b)
        if read_err == .ShortRead {
            // fine as long as b.data is left untouched
            (cast(^mem.Raw_Dynamic_Array)&b.data).len = len_mark
            b.r_offset = r_offset_mark
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
peek_var_int :: proc(b: ^NetworkBuffer) -> (val: VarInt, nbytes: int, err: ReadError) {
    pos: u16

    for {
        curr := peek_byte(b, pos / 7) or_return
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
read_var_long :: proc(b: ^NetworkBuffer) -> (val: VarLong, err: ReadError) {
    len_mark := len(b.data)
    r_offset_mark := b.r_offset
    pos: u16

    for {
        curr, read_err := read_byte(b)
        if read_err == .ShortRead {

            // fine as long as b.data is left untouched
            (cast(^mem.Raw_Dynamic_Array)&b.data).len = len_mark
            b.r_offset = r_offset_mark
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

@(require_results)
read_nbytes :: proc(b: ^NetworkBuffer, #any_int n: int, allocator := context.allocator) -> (dest: []u8, err: ReadError) #no_bounds_check {
    // TODO: avoid allocation; we cant slice into r.data as this is non-contiguous
    // perhaps we can slice into the network received bytes?
    // when does this even get deallocated?
    // TODO: when n is zero, return early?
    ensure_readable(b^, n) or_return
    dest = make([]u8, n, allocator)

    // bytes copyable from read offset to boundary (array end or length)
    // FIXME: can this be done with less branches?
    n_nowrap := min(n, cap(b.data) - b.r_offset, len(b.data))
    intrinsics.mem_copy_non_overlapping(raw_data(dest), raw_data(b.data[b.r_offset:]), n_nowrap)

    if n > n_nowrap {
        intrinsics.mem_copy_non_overlapping(raw_data(dest[n_nowrap:]), raw_data(dest), n - n_nowrap)
    }

    b.r_offset = (b.r_offset + n) % cap(b.data)
    (cast(^mem.Raw_Dynamic_Array)&b.data).len -= n
    return dest, .None
}

@(require_results)
ensure_readable :: proc(b: NetworkBuffer, #any_int n: int) -> ReadError {
    assert(n >= 0) // FIXME: can we formally assert this is always the case?
    #assert(ReadError(0) == .None)
    #assert(ReadError(1) == .ShortRead)
    return ReadError(len(b.data) < n)
}

// Advances `n` bytes
advance_pos_unchecked :: proc(b: ^NetworkBuffer, n: int) {
    (cast(^mem.Raw_Dynamic_Array)&b.data).len -= n
    b.r_offset = (b.r_offset + n) % cap(b.data)
}

@(require_results)
read_u16 :: proc(b: ^NetworkBuffer) -> (u: u16be, err: ReadError) {
    ensure_readable(b^, 2) or_return
    msb := unchecked_read_byte(b)
    lsb := unchecked_read_byte(b)
    return u16be(msb) << 8 | u16be(lsb), .None
}

@(require_results)
consume_u16 :: proc(b: ^NetworkBuffer, u: u16) -> (match: bool, err: ReadError) #no_bounds_check {
    ensure_readable(b^, 2) or_return
    msb := b.data[b.r_offset]
    lsb := b.data[(b.r_offset + 1) % cap(b.data)]
    if (u16(msb) << 8) | u16(lsb) == u {
        (cast(^mem.Raw_Dynamic_Array)&b.data).len -= 2
        b.r_offset = (b.r_offset + 2) % cap(b.data)
        return true, .None
    }
    return false, .None
}

@(require_results)
consume_byte :: proc(b: ^NetworkBuffer, expected: u8) -> (match: bool, err: ReadError) #no_bounds_check {
    ensure_readable(b^, 1) or_return
    if b.data[b.r_offset] == expected {
        b.r_offset = (b.r_offset + 1) % cap(b.data)
        return true, .None
    }
    return false, .None
}

@(require_results)
read_byte :: proc(b: ^NetworkBuffer) -> (u8, ReadError) #no_bounds_check {
    if len(b.data) == 0 do return 0, .ShortRead
    (cast(^mem.Raw_Dynamic_Array)&b.data).len -= 1
    defer b.r_offset = (b.r_offset + 1) % cap(b.data)
    return b.data[b.r_offset], .None
}

@(require_results)
peek_byte :: proc(b: ^NetworkBuffer, #any_int off := 0) -> (u8, ReadError) #no_bounds_check {
    if len(b.data) <= off do return 0, .ShortRead
    return b.data[(b.r_offset + off) % cap(b.data)], .None
}

@(require_results)
unchecked_read_byte :: proc(b: ^NetworkBuffer) -> u8 #no_bounds_check {
    defer b.r_offset = (b.r_offset + 1) % cap(b.data)
    return b.data[b.r_offset]
}
