package crux

import "core:mem"

import "base:intrinsics"

SEGMENT_BITS :: 0x7F
CONTINUE_BIT :: 0x80

// Per client buffer, where network calls store their data,
// may be reallocated to fit a whole packet.
// No attempts are made to read more data from the socket.
// This type only resizes when no more space is available.
// Not thread-safe.
NetworkBuffer :: struct {
    // len(data) should never be considered, always use len
    // FIXME: place length in there instead of another field??
    data: [dynamic]u8,
    len: int,
    r_offset: int,
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
    space := cap(b.data) - b.len
    nrequired := len(data)
    if space < nrequired {
        grow(b, additional=nrequired)
    }

    alloc_sz := cap(b.data)
    insert_from := (b.r_offset + b.len) % alloc_sz // always rightmost write
    if insert_from + nrequired > alloc_sz {
        n_nowrap := alloc_sz - insert_from
        // limit copy to amount of items that fits without wrapping, and perform another copy
        intrinsics.mem_copy_non_overlapping(raw_data(b.data[insert_from:]), raw_data(data), n_nowrap)
        intrinsics.mem_copy_non_overlapping(raw_data(b.data), raw_data(data[n_nowrap:]), nrequired - n_nowrap)
    } else {
        intrinsics.mem_copy_non_overlapping(raw_data(b.data[insert_from:]), raw_data(data), nrequired)
    }
    b.len += nrequired
}

// Grows the internal buffer, with at least `additional` bytes
// FIXME: verify this "at least" is correct
@(private="file")
grow :: proc(b: ^NetworkBuffer, additional: int) {
    old_len := b.len
    when ODIN_DEBUG do assert(old_len > 0)
    new_cap := max(old_len * 2, old_len + additional)

    reserve(&b.data, new_cap)
    when ODIN_DEBUG do assert(cap(b.data) == new_cap)
    // ensure wrapped around data is correctly positioned at the end of the new allocation
    // | \\\ |     | /// | /// | ...new allocation | -> move block 3 and 4
    //  -----W-----R----- -----
    if b.r_offset + b.len > old_len {
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

@(require_results)
read_var_int :: proc(b: ^NetworkBuffer) -> (val: VarInt, err: ReadError) {
    pos: u16

    for {
        curr := read_byte(b) or_return
        val |= auto_cast (curr & SEGMENT_BITS) << pos
        if curr & CONTINUE_BIT == 0 do break

        pos += 7
        if pos >= 32 {
            return val, .InvalidData // too big
        }
    }
    return val, .None
}

@(require_results)
read_var_long :: proc(b: ^NetworkBuffer) -> (val: VarLong, err: ReadError) {
    pos: u16

    for {
        curr := read_byte(b) or_return
        val |= auto_cast (curr & SEGMENT_BITS) << pos
        if curr & CONTINUE_BIT == 0 do break

        pos += 7
        if pos >= 64 {
            // too big
            return val, .InvalidData
        }
    }
    return val, .None
}

@(require_results)
read_nbytes :: proc(b: ^NetworkBuffer, #any_int n: int, allocator := context.allocator) -> (s: []u8, err: ReadError) #no_bounds_check {
    // TODO(urgent): avoid allocation; we cant slice into r.data as this is non-contiguous
    // perhaps we can slice into the network received bytes?
    // when does this even get deallocated?
    // FIXME: when n is zero, return early?
    ensure_readable(b^, n) or_return
    s = make([]u8, n, allocator)
    n_nowrap := len(b.data) - b.r_offset

    if n > n_nowrap {
        intrinsics.mem_copy_non_overlapping(raw_data(s), raw_data(b.data[b.r_offset:]), n_nowrap)
        n_wrap := n - n_nowrap
        intrinsics.mem_copy_non_overlapping(raw_data(s[n_nowrap:]), raw_data(b.data[:n_wrap]), n_wrap)
    } else {
        intrinsics.mem_copy_non_overlapping(raw_data(s), raw_data(b.data[b.r_offset:]), n)
    }
    b.r_offset = (b.r_offset + n) % cap(b.data)
    b.len -= n
    return s, .None
}

@(require_results)
ensure_readable :: proc(r: NetworkBuffer, #any_int n: int) -> ReadError {
    assert(n >= 0) // FIXME: can we formally assert this is always the case?
    #assert(ReadError(0) == .None)
    #assert(ReadError(1) == .ShortRead)
    return ReadError(r.len < n)
}

@(require_results)
read_u16 :: proc(b: ^NetworkBuffer) -> (u: u16be, err: ReadError) {
    ensure_readable(b^, 2) or_return
    msb := unchecked_read_byte(b)
    lsb := unchecked_read_byte(b)
    return u16be(msb) << 8 | u16be(lsb), .None
}

// TODO: those no_bounds_check have as side effect that we can read beyond len(b.data),
// as we never set b.data.len but use b.len instead

@(require_results)
consume_u16_if :: proc(b: ^NetworkBuffer, u: u16) -> (match: bool, err: ReadError) #no_bounds_check {
    ensure_readable(b^, 2) or_return
    msb := b.data[b.r_offset]
    lsb := b.data[(b.r_offset + 1) % cap(b.data)]
    if (u16(msb) << 8) | u16(lsb) == u {
        b.len -= 2
        b.r_offset = (b.r_offset + 2) % cap(b.data)
        return true, .None
    }
    return false, .None
}

@(require_results)
read_byte :: proc(b: ^NetworkBuffer) -> (u8, ReadError) #no_bounds_check {
    if b.len == 0 do return 0, .ShortRead
    b.len -= 1
    defer b.r_offset = (b.r_offset + 1) % cap(b.data)
    return b.data[b.r_offset], .None
}

@(require_results)
unchecked_read_byte :: proc(b: ^NetworkBuffer) -> u8 #no_bounds_check {
    defer b.r_offset = (b.r_offset + 1) % cap(b.data)
    return b.data[b.r_offset]
}
