package crux

import "core:strings"
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"

import "base:intrinsics"

// 7 least significant bits are used to encode the value,
// most significant bit indicates whether there's another byte
VarInt :: distinct i32le
VarLong :: distinct i64le

Long :: distinct i64be

Utf16String :: distinct []u8

MAX_VAR_INT :: int(max(VarInt))

SEGMENT_BITS :: 0x7F
CONTINUE_BIT :: 0x80
MIN_STRING_LENGTH :: 1
MAX_STRING_LENGTH :: 32767

IDENTIFIER_MAX_LENGTH :: 32767

@(init, private)
_init :: proc "contextless" () {
    context = {} // no actual context is used below
    allowed_identifier_chars = strings.ascii_set_make("abcdefghijklmnopqrstuvwxyz0123456789.-_") or_else panic("invariant")
}

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

create_network_buf :: proc(cap := 512, allocator: mem.Allocator) -> (buf: NetworkBuffer) {
    assert(cap > 0)
    buf.data = make([dynamic]u8, 0, cap, allocator)
    return
}

destroy_network_buf :: proc(buf: NetworkBuffer) {
    delete(buf.data)
}

ReadError :: enum {
    None      = 0,
    ShortRead = 1,
    InvalidData,
}

WriteError :: enum {
    None,
    // BufWriteMark provided to `write_at` operation is stale or is not valid at all.
    InvalidMark,
    StringTooLong,
}

// An insertion position into a NetworkBuffer, this mark is only valid if it points
// to a position in the data chunk formed between the read and write offset.
BufWriteMark :: distinct int

// Dumps a NetworkBuffer to stdout, for debugging purposes.
buf_dump :: proc(buf: NetworkBuffer) #no_bounds_check {
    fmt.printfln("NetworkBuffer{{len=%d, r_offset=%d, data=%2x (hex)}}",
        len(buf.data), buf.r_offset, buf.data[buf.r_offset:][:len(buf.data)],
    )
}

// Creates a `BufWriteMark`, a position referring to the current writing offset.
// This can be used for later writes at a certain offset.
buf_emit_write_mark :: proc(buf: NetworkBuffer) -> BufWriteMark {
    return BufWriteMark((buf.r_offset + len(buf.data)) % cap(buf.data))
}

// Returns the number of total bytes in this buffer.
@(require_results)
buf_length :: proc(buf: NetworkBuffer) -> int {
    return len(buf.data)
}

// Checks whether `n` bytes are readable, returns .ShortRead if not.
@(require_results)
buf_ensure_readable :: proc(buf: NetworkBuffer, #any_int n: int) -> ReadError {
    #assert(ReadError(0) == .None)
    #assert(ReadError(1) == .ShortRead)
    return ReadError(len(buf.data) < n)
}

// Advances `n` bytes
buf_advance_pos_unchecked :: proc(buf: ^NetworkBuffer, n: int) {
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= n
    buf.r_offset = (buf.r_offset + n) % cap(buf.data)
}

@(require_results)
buf_write_string :: proc(buf: ^NetworkBuffer, str: string) -> WriteError {
    if len(str) > MAX_STRING_LENGTH {
        return .StringTooLong
    }
    buf_write_var_int(buf, VarInt(len(str)))
    buf_write_bytes(buf, transmute([]u8)str)
    return .None
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
        intrinsics.mem_copy_non_overlapping(&buf.data[w_offset], &data[0], n_nowrap)
        intrinsics.mem_copy_non_overlapping(&buf.data[0], &data[n_nowrap], nrequired - n_nowrap)
    } else {
        intrinsics.mem_copy_non_overlapping(&buf.data[w_offset], &data[0], nrequired)
    }
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len += nrequired
}

buf_write_var_int :: proc(buf: ^NetworkBuffer, val: VarInt) {
    // to prevent sign extension on negative numbers
    val := u32le(val)
    #assert(size_of(u32le) == size_of(VarInt))
    for {
        if val & ~u32le(SEGMENT_BITS) == 0 {
            buf_write_byte(buf, u8(val))
            return
        }
        buf_write_byte(buf, u8(val) & SEGMENT_BITS | CONTINUE_BIT)
        val >>= 7
    }
    unreachable()
}

buf_write_var_int_at :: proc(buf: ^NetworkBuffer, mark: BufWriteMark, val: VarInt) -> WriteError #no_bounds_check {
    mark_idx := int(mark) // index into raw data
    // wrapped meaning, both sides of the data array are being used to store data, with an
    // eventual empty chunk between those sides
    wrapped := buf.r_offset + len(buf.data) > cap(buf.data)
    w_offset := (buf.r_offset + len(buf.data)) % cap(buf.data)
    
    // ensure we are not creating "holes" by writing outside the data chunk formed between the read and write offset.
    // examples of invalid mark positions:
    // |     | /// | /// |     |
    // M-----R-----|-----W-----|
    //
    // | /// | /// |     |     |
    // |-----|-----|-----M-----|
    // TODO: add guard for wrapped structure
    if !wrapped && (mark_idx > w_offset || mark_idx < buf.r_offset) {
        return .InvalidMark
    }
    
    // if wrapped && (uint())

    vbuf, vlen := _buf_prepare_var_int(val)
    space := cap(buf.data) - len(buf.data)
    if space < vlen {
        _buf_reserve_exact(buf, len(buf.data) + vlen)
    }

    // |     | /// | /// |     |
    // |-----R-----M-----W-----|
    // (move data between mark and write offset to make VarInt fit)
    if wrapped {
        panic("yet to be implemented")
    } else {
        // W >= M for all cases
        move_len := w_offset - mark_idx // >= 0
        
        if move_len > 0 {
            // amount of bytes that can be positioned behind the newly inserted vbuf (can be pos/neg/zero) (<= move_len)
            // when negative, this tells the number of bytes that needs to wrap around
            trailing_unused := cap(buf.data) - mark_idx - vlen
            trailing_move_len := min(move_len, trailing_unused) // any real number
            
            if trailing_unused > 0 {
                intrinsics.mem_copy(&buf.data[mark_idx + vlen], &buf.data[mark_idx], trailing_move_len)
            }
            
            // if trailing_move_len == move_len -> everything was moved
            // if trailing_move_len < move_len  -> more bytes need to be moved to the front
            // if trailing_move_len <= 0        -> move abs(trailing_move_len) to front
            if trailing_move_len < move_len {
                trailing_move_abs := abs(trailing_move_len)
                leading_move_len := move_len - trailing_move_abs
                insert_at := (mark_idx + vlen) % cap(buf.data)
                intrinsics.mem_copy_non_overlapping(&buf.data[insert_at], &buf.data[mark_idx + trailing_move_abs], leading_move_len)
            }
        }
    }

    for b, i in vbuf[:vlen] {
        offset := (mark_idx + i) % cap(buf.data)
        buf.data[offset] = b
    }

    (cast(^mem.Raw_Dynamic_Array)&buf.data).len += vlen
    return .None
}

@(private)
_buf_prepare_var_int :: proc(val: VarInt) -> (buf: [5]u8, n: int) {
    val := cast(u32le) val
    for _, i in buf {
        if val & ~u32le(SEGMENT_BITS) == 0 {
            buf[i] = u8(val)
            return buf, i + 1
        }
        buf[i] = u8(val & SEGMENT_BITS | CONTINUE_BIT)
        val >>= 7
    }
    unreachable()
}

buf_write_long :: proc(buf: ^NetworkBuffer, val: Long) {
    val := val
    bytes := (cast([^]u8)&val)[:8]
    buf_write_bytes(buf, bytes)
}

buf_write_byte :: proc(buf: ^NetworkBuffer, b: u8) #no_bounds_check {
    space := cap(buf.data) - len(buf.data)
    if space == 0 {
        _buf_reserve(buf)
    }
    buf.data[buf.r_offset + len(buf.data)] = b
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len += 1
}

// FIXME: inline?
@(private="file")
_buf_reserve :: proc(buf: ^NetworkBuffer) {
    _buf_reserve_exact(buf, max(16, len(buf.data) * 2))
}

// TODO: get rid of this and use a * 2 growth strategy
@(private="file")
_buf_reserve_exact :: proc(buf: ^NetworkBuffer, new_cap: int) #no_bounds_check {
    old_cap := cap(buf.data)

    reserve(&buf.data, new_cap)
    // ensure wrapped around data is correctly positioned at the end of the new allocation
    // | \\\ |     | /// | /// | ...new allocation | -> move block 3 and 4 to the end
    // |-----W-----R-----|-----|
    if buf.r_offset + len(buf.data) > old_cap {
        to_copy := old_cap - buf.r_offset
        intrinsics.mem_copy_non_overlapping(&buf.data[new_cap - to_copy], &buf.data[buf.r_offset], to_copy)
        buf.r_offset = new_cap - to_copy
    }
}

// Allowed Identifier chars, excluding the ones that are only exclusively used in either the namespace or value.
@(private="file")
allowed_identifier_chars: strings.Ascii_Set

@(require_results)
buf_read_identifier :: proc(buf: ^NetworkBuffer, allocator: mem.Allocator) -> (id: Identifier, err: ReadError) {
    length := buf_read_var_int(buf) or_return
    if length == 0 || length > IDENTIFIER_MAX_LENGTH {
        return id, .InvalidData
    }

    bytes := make([]u8, length, allocator)
    buf_read_bytes(buf, bytes) or_return
    
    seen_separator := false
    for c, i in bytes {
        if strings.ascii_set_contains(allowed_identifier_chars, c) do continue
        
        if c == ':' { // value separator
            if seen_separator || len(bytes) == i + 1 {
                return id, .InvalidData
            }
            seen_separator = true
        } else if c == '/' && !seen_separator {
            return id, .InvalidData
        }
    }
    return Identifier(bytes), .None
}

@(require_results)
buf_read_flags :: proc(buf: ^NetworkBuffer, $T: typeid/bit_set[$F]) -> (flags: T, err: ReadError) {
    outb: [size_of(T)]u8
    buf_read_bytes(buf, outb[:]) or_return
    flags = transmute(T) outb
    
    check_bit: for flag in flags {
        for f in F {
            if flag == f do continue check_bit
        }
        return flags, .InvalidData
    }
    return flags, .None
}

@(require_results)
buf_read_uuid :: proc(buf: ^NetworkBuffer) -> (id: uuid.Identifier, err: ReadError) {
    outb: [16]u8
    buf_read_bytes(buf, outb[:]) or_return
    return uuid.Identifier(outb), .None
}

buf_write_uuid :: proc(buf: ^NetworkBuffer, id: uuid.Identifier) {
    id := id
    buf_write_bytes(buf, id[:])
}

// FIXME: handle address decoding
@(require_results)
buf_read_string :: proc(buf: ^NetworkBuffer, #any_int max_len: int, allocator: mem.Allocator) -> (s: string, err: ReadError) {
    length := buf_read_var_int(buf) or_return
    if length < MIN_STRING_LENGTH || int(length) > max_len {
        return s, .InvalidData
    }
    outb := make([]u8, length, allocator)
    buf_read_bytes(buf, outb) or_return
    return string(outb), .None
}

buf_read_long :: proc(buf: ^NetworkBuffer) -> (l: Long, err: ReadError) {
    out: [8]u8
    buf_read_bytes(buf, out[:]) or_return
    return transmute(Long)out, .None
}

@(require_results)
buf_read_var_int_enum :: proc(buf: ^NetworkBuffer, $E: typeid) -> (e: E, err: ReadError)
where
    intrinsics.type_is_enum(E) {
    e = cast(E) buf_read_var_int(buf) or_return
    
    when intrinsics.type_enum_is_contiguous(E) {
        if e < min(E) || e > max(E) {
            return e, .InvalidData
        }
        return e, .None
    } else {
        for constant in E do if constant == e {
            return e, .None
        }
        return e, .InvalidData
    }
}

@(require_results)
buf_unchecked_read_var_int_enum :: proc(buf: ^NetworkBuffer, $E: typeid) -> (e: E, err: ReadError)
where
    intrinsics.type_is_enum(E) {
    e = cast(E) buf_unchecked_read_var_int(buf) or_return
    
    when intrinsics.type_enum_is_contiguous(E) {
        if e < min(E) || e > max(E) {
            return e, .InvalidData
        }
        return e, .None
    } else {
        for constant in E do if constant == e {
            return e, .None
        }
        return e, .InvalidData
    }
}

@(require_results)
buf_read_int :: proc(buf: ^NetworkBuffer) -> (val: i32be, err: ReadError) {
    buf_ensure_readable(buf^, 4) or_return
    #unroll for _ in 0..=3 {
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
            (cast(^mem.Raw_Dynamic_Array)&buf.data).len = len_mark
            buf.r_offset = r_offset_mark
            return 0, .ShortRead
        }
        read_err or_return

        val |= VarInt(curr & SEGMENT_BITS) << pos
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
        val |= VarInt(curr & SEGMENT_BITS) << pos
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
            (cast(^mem.Raw_Dynamic_Array)&buf.data).len = len_mark
            buf.r_offset = r_offset_mark
            return 0, .ShortRead
        }
        val |= VarLong(curr & SEGMENT_BITS) << pos
        pos += 7

        if curr & CONTINUE_BIT == 0 do break

        if pos >= 64 {
            // too big
            return val, .InvalidData
        }
    }
    return val, .None
}

// See ´buf_copy_into´, additionally, the internal state is updated to reflect the consumed bytes.
@(require_results)
buf_read_bytes :: proc(buf: ^NetworkBuffer, outb: []u8) -> ReadError #no_bounds_check {
    buf_copy_into(buf, outb) or_return
    n := len(outb)
    
    buf.r_offset = (buf.r_offset + n) % cap(buf.data)
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= n
    return .None
}

// Copies `len(outb)` bytes from this buffer into `outb` (starting from the read offset), `ReadError.ShortRead` is returned
// when not enough bytes are available, the internal state is not updated, merely a copy is made.
@(require_results)
buf_copy_into :: proc(buf: ^NetworkBuffer, outb: []u8) -> ReadError #no_bounds_check {
    n := len(outb)
    buf_ensure_readable(buf^, n) or_return

    // bytes copyable from read offset to boundary (array end or length)
    n_nowrap := min(n, cap(buf.data) - buf.r_offset, len(buf.data))
    intrinsics.mem_copy_non_overlapping(raw_data(outb), &buf.data[buf.r_offset], n_nowrap)

    if n > n_nowrap {
        intrinsics.mem_copy_non_overlapping(&outb[n_nowrap], raw_data(outb), n - n_nowrap)
    }
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

buf_unchecked_read_bool :: proc(buf: ^NetworkBuffer) -> (bool, ReadError) {
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= 1
    defer buf.r_offset = (buf.r_offset + 1) % cap(buf.data)
    b := buf.data[buf.r_offset]
    if b > 1 {
        return false, .InvalidData
    }
    return bool(b), .None
}

@(require_results)
buf_read_bool :: proc(buf: ^NetworkBuffer) -> (bool, ReadError) #no_bounds_check {
    if len(buf.data) == 0 do return false, .ShortRead
    (cast(^mem.Raw_Dynamic_Array)&buf.data).len -= 1
    defer buf.r_offset = (buf.r_offset + 1) % cap(buf.data)
    b := buf.data[buf.r_offset]
    if b > 1 {
        return false, .InvalidData
    }
    return bool(b), .None
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
