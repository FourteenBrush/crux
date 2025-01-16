package crux

import "core:fmt"
import "core:mem"
import "core:container/queue"

import "base:intrinsics"

_ :: mem

SEGMENT_BITS :: 0x07
CONTINUE_BIT :: 0x08

// Per client buffer, where network calls store their data,
// may be reallocated to fit a whole packet.
// No attempts are made to read more data from the socket
NetworkBuffer :: struct {
    buf: queue.Queue(u8),
}

create_packet_reader :: proc(allocator := context.allocator) -> (reader: NetworkBuffer) {
    queue.init(&reader.buf, allocator=allocator)
    return
}

destroy_packet_reader :: proc(r: ^NetworkBuffer) {
    queue.destroy(&r.buf)
}

push_data :: proc(r: ^NetworkBuffer, data: []u8) {
    queue.append(&r.buf, ..data)
}

read_serverbound :: proc(r: ^NetworkBuffer) -> (p: ServerboundPacket, ok: bool) {
    ensure_readable(r^, size_of(VarInt) + size_of(PacketId)) or_return
    id := read_var_int(r) or_return
    length := read_var_int(r) or_return
    ensure_readable(r^, length) or_return

    #partial switch PacketId(id) {
    case .Handshake:
        protocol_version := read_var_int(r) or_return
        server_addr_len := read_var_int(r) or_return
        fmt.println(protocol_version, server_addr_len)

        // FIXME: handle address decoding
        fmt.println(server_addr_len, queue.len(r.buf))
        ensure_readable(r^, server_addr_len) or_return
        server_port := read_u16(r) or_return
        next_state := NextState(read_var_int(r) or_return)
        return HandshakePacket {
            protocol_version = protocol_version,
            server_addr = {}, // TODO
            server_port = server_port,
            next_state = next_state,
        }, true
    }
    unimplemented("TODO")
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
    if queue.len(r.buf) < required do return

    //                ________________
    // read end, back |\\\|      |\\\| write end, front

    front_size := min(required, len(r.buf.data) - int(r.buf.offset))
    front_ptr := queue.front_ptr(&r.buf)
    mem.copy_non_overlapping(&val, front_ptr, front_size)

    back_size := required - front_size
    mem.copy_non_overlapping(
        raw_data(mem.ptr_to_bytes(&val)[:front_size]),
        raw_data(r.buf.data[:back_size]),
        back_size,
    )

    when ODIN_DEBUG {
        mem.zero(front_ptr, front_size)
        mem.zero_slice(r.buf.data[:back_size])
    }

    queue.consume_front(&r.buf, required)
    return val, true
}

@(require_results)
ensure_readable :: proc(r: NetworkBuffer, #any_int n: uint) -> bool {
    return queue.len(r.buf) >= int(n)
}

// incredibly inefficient impl for now

read_u16 :: proc(r: ^NetworkBuffer) -> (u: u16be, ok: bool) {
    lsb := queue.pop_front_safe(&r.buf) or_return
    msb := queue.pop_front_safe(&r.buf) or_return
    return u16be(msb << 8 | lsb), true
}

read_byte :: proc(r: ^NetworkBuffer) -> (u8, bool) {
    return queue.pop_front_safe(&r.buf)
}

unchecked_read_byte :: proc(r: ^NetworkBuffer) -> u8 {
    return queue.pop_front(&r.buf)
}
