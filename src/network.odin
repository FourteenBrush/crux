#+private
package crux

import "core:mem"
import "core:container/queue"

import "base:intrinsics"

_ :: mem

SEGMENT_BITS :: 0x07
CONTINUE_BIT :: 0x08

// 7 least significant bits are used to encode the value,
// most significant bits indicate whether there's another byte
VarInt :: distinct i32
VarLong :: distinct i64

// Per client buffer, where network calls store their data,
// may be reallocated to fit a whole packet.
// No attempts are made to read more data from the socket
NetworkBuffer :: struct {
    read_buf: queue.Queue(u8),
}

create_packet_reader :: proc(allocator := context.allocator) -> (reader: NetworkBuffer) {
    queue.init(&reader.read_buf, allocator=allocator)
    return
}

destroy_packet_reader :: proc(r: ^NetworkBuffer) {
    queue.destroy(&r.read_buf)
}

push_data :: proc(r: ^NetworkBuffer, data: []u8) {
    queue.append(&r.read_buf, ..data)
}

read_var_int :: proc(r: ^NetworkBuffer) -> (val: VarInt, ok: bool) {
    pos: uint
    curr: u8
    for {
        curr = read_byte(r) or_return
        val |= auto_cast (curr & SEGMENT_BITS) << pos
        if curr & CONTINUE_BIT == 0 do break

        pos += 7
        if pos >= 32 do return // too big
    }
    return val, true
}

read_var_long :: proc(r: ^NetworkBuffer) -> (val: VarLong, ok: bool) {
    pos: uint
    curr: u8

    for {
        curr = read_byte(r) or_return
        val |= auto_cast (curr & SEGMENT_BITS) << pos

        if curr & CONTINUE_BIT == 0 do break

        pos += 7
        if pos >= 64 do return // too big
    }
    return val, true
}

read_packed :: proc(r: ^NetworkBuffer, $T: typeid) -> (val: T, ok: bool)
where
    !intrinsics.type_struct_has_implicit_padding(T)
{
    required :: size_of(T)
    if queue.len(r.read_buf) < required do return

    //                ________________
    // read end, back |\\\|      |\\\| write end, front

    // sizes as in front/back of the ring buffer
    front_size := min(required, len(r.read_buf.data) - int(r.read_buf.offset))
    front_ptr := queue.front_ptr(&r.read_buf)
    mem.copy_non_overlapping(&val, front_ptr, front_size)

    back_size := required - front_size
    mem.copy_non_overlapping(
        raw_data(mem.ptr_to_bytes(&val)[:front_size]),
        raw_data(r.read_buf.data[:back_size]),
        back_size,
    )

    when ODIN_DEBUG {
        mem.zero(front_ptr, front_size)
        mem.zero_slice(r.read_buf.data[:back_size])
    }

    queue.consume_front(&r.read_buf, required)
    return val, true
}

@(require_results)
ensure_readable :: proc(r: NetworkBuffer, #any_int n: uint) -> bool {
    return queue.len(r.read_buf) >= int(n)
}

read_byte :: proc(r: ^NetworkBuffer) -> (u8, bool) {
    return queue.pop_front_safe(&r.read_buf)
}

unchecked_read_byte :: proc(r: ^NetworkBuffer) -> u8 {
    return queue.pop_front(&r.read_buf)
}
