package crux

import "core:log"
import "core:mem"
import "base:intrinsics"
import "core:encoding/json"

import "lib:tracy"

import "src:reactor"

enqueue_packet :: proc(io_ctx: ^reactor.IOContext, client_conn: ^ClientConnection, packet: ClientBoundPacket) {
    tracy.Zone()
    log.log(LOG_LEVEL_OUTBOUND, "Sending packet", packet)

    _serialize_clientbound(packet, &client_conn.tx_buf)
    
    // freed by io worker after receiving write completion
    outb := make([]u8, buf_length(client_conn.tx_buf), client_conn.packet_scratch_alloc)
    read_err := buf_copy_into(&client_conn.tx_buf, outb)
    assert(read_err == .None, "invariant, copied full length")

    submission_ok := reactor.submit_write_copy(io_ctx, client_conn.handle, outb)
    assert(submission_ok, "TODO: submission errors")
    buf_advance_pos_unchecked(&client_conn.tx_buf, len(outb))
}

_serialize_clientbound :: proc(packet: ClientBoundPacket, outb: ^NetworkBuffer) {
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
        bytes := json.marshal(packet, allocator=context.temp_allocator) or_else panic("error serializing status response")
        werr := buf_write_string(outb, string(bytes)) // copied
        assert(werr == .None, "max string length exceeded") // TODO
    case PongResponsePacket:
        buf_write_long(outb, packet.payload)
    case LoginSuccessPacket:
        buf_write_uuid(outb, packet.uuid)
        _ = buf_write_string(outb, packet.username)
        // properties
        buf_write_var_int(outb, VarInt(1)) // 1 property
        _ = buf_write_string(outb, packet.name)
        _ = buf_write_string(outb, packet.value)
        
        // optional signature
        buf_write_byte(outb, 1 if packet.signature != nil else 0)
        if signature, ok := packet.signature.?; ok {
            _ = buf_write_string(outb, signature)
        }
    case DisconnectPacket:
        // TODO
    case PluginMessagePacket:
        buf_write_identifier(outb, packet.channel)
        buf_write_bytes(outb, packet.payload)
    }
}
