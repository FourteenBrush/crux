package crux

import "core:log"
import "core:net"
import "core:mem"
import "core:encoding/json"

enqueue_packet :: proc(client_conn: ^ClientConnection, packet: ClientBoundPacket, allocator: mem.Allocator) -> bool {
    log.info("sending packet", packet)
    _serialize_clientbound(packet, &client_conn.tx_buf, allocator=allocator)

    // TODO: ensure contiguous, also what happens when kernel buf is full?
    n, send_err := net.send(client_conn.socket, client_conn.tx_buf.data[:])
    assert(n == len(client_conn.tx_buf.data))
    assert(send_err == nil)
    return true
}

_serialize_clientbound :: proc(packet: ClientBoundPacket, outb: ^NetworkBuffer, allocator: mem.Allocator) {
    initial_len := buf_remaining(outb^)
    begin_payload_mark := buf_emit_write_mark(outb^)
    defer {
        // FIXME: can we instead of moving data, reserve space for a (too long) encoded VarInt
        payload_len := buf_remaining(outb^) - initial_len
        err := buf_write_var_int_at(outb, begin_payload_mark, VarInt(payload_len))
        assert(err == .None, "invariant, mark could not have become invalid")
    }

    packet_id := get_clientbound_packet_id(packet)
    buf_write_var_int(outb, VarInt(packet_id))

    switch packet in packet {
    case StatusResponsePacket:
        bytes, err := json.marshal(packet, allocator=allocator)
        // TODO: better error handling, would be weird that this type wouldn't be serializable
        assert(err == nil, "error serializing status response packet to json")
        werr := buf_write_string(outb, string(bytes))
        assert(werr == .None)
    case PongResponse:
        buf_write_long(outb, packet.payload)
    }
}
