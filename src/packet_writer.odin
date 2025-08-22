package crux

import "base:runtime"
import "core:log"
import "core:net"
import "core:mem"
import "core:encoding/json"

enqueue_packet :: proc(client_conn: ^ClientConnection, packet: ClientBoundPacket, allocator: mem.Allocator) -> bool {
    log.info("sending packet", packet)
    _serialize_clientbound(packet, &client_conn.tx_buf, allocator=allocator)

    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    tx_buf := make([]u8, buf_length(client_conn.tx_buf), context.temp_allocator)
    _ = buf_copy_into(&client_conn.tx_buf, tx_buf) // copies full contents, ignore impossible short reads
    
    n, send_err := net.send_tcp(client_conn.socket, tx_buf)
    assert(send_err == .None || send_err == .Would_Block, "send() failed")
    // kernel buf might not be able to hold full data, send remaining data next time
    // (send_tcp() calls send() repeatedly in a loop, till any error occurs)
    buf_advance_pos_unchecked(&client_conn.tx_buf, n)
    return true
}

_serialize_clientbound :: proc(packet: ClientBoundPacket, outb: ^NetworkBuffer, allocator: mem.Allocator) {
    initial_len := buf_length(outb^)
    begin_payload_mark := buf_emit_write_mark(outb^)
    defer {
        // FIXME: can we instead of moving data, reserve space for a (unnecessarily long) encoded VarInt
        payload_len := buf_length(outb^) - initial_len
        err := buf_write_var_int_at(outb, begin_payload_mark, VarInt(payload_len))
        assert(err == .None, "invariant, mark could not have become invalid")
    }

    packet_id := get_clientbound_packet_id(packet)
    buf_write_var_int(outb, VarInt(packet_id))

    switch packet in packet {
    case StatusResponsePacket:
        // json serializer does not return allocator errors, so there should be no reason this fails
        bytes := json.marshal(packet, allocator=allocator) or_else panic("error serializing status response")
        werr := buf_write_string(outb, string(bytes))
        assert(werr == .None, "max string length exceeded") // TODO
    case PongResponse:
        buf_write_long(outb, packet.payload)
    }
}
