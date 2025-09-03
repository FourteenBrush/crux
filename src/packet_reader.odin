package crux

import "core:log"
import "core:mem"

read_serverbound :: proc(b: ^NetworkBuffer, client_state: ClientState, allocator: mem.Allocator) -> (p: ServerBoundPacket, err: ReadError) {
    if buf_consume_byte(b, 0xfe) or_return {
        // NOTE: vanilla client attempts to send a legacy server list ping packet
        // when normal ping times out (30s), additionally older clients send this, which
        // we are supposed to handle
        // TODO: directly kick after FE 01 FA
        return read_legacy_server_list_ping(b, allocator=allocator)
    }

    // early return on short read, no bytes consumed
    length, length_nbytes := buf_peek_var_int(b) or_return
    buf_ensure_readable(b^, length) or_return

    buf_advance_pos_unchecked(b, length_nbytes)
    id := buf_read_var_int(b) or_return

    switch ServerBoundPacketId(id) {
    case .Handshake: // shared with .StatusRequest and LoginStart, blame the protocol
        #partial switch client_state {
        case .Handshake:
            return HandshakePacket {
                protocol_version = read_protocol_version(b) or_return,
                server_addr = buf_read_string(b, 255, allocator) or_return,
                server_port = buf_read_u16(b) or_return,
                intent = buf_read_var_int_enum(b, HandshakeIntent) or_return,
            }, .None
        case .Status:
            return StatusRequestPacket {}, .None
        case .Login:

            return LoginStartPacket {
                username = buf_read_string(b, 16, allocator) or_return,
                uuid = buf_read_uuid(b) or_return,
            }, .None
        case:
            return p, .InvalidData
        }

    case .PingRequest:
        payload := buf_read_long(b) or_return
        return PingRequestPacket { payload }, .None
    case .LoginAcknowledged:
        return LoginAcknowledgedPacket {}, .None
    case:
        log.warn("unhandled packet id:", ServerBoundPacketId(id), "kicking with .InvalidData")
        return p, .None
    }
}

// Reads a legacy server list ping packet, the initial byte 0xfe has already been read.
read_legacy_server_list_ping :: proc(buf: ^NetworkBuffer, allocator: mem.Allocator) -> (p: LegacyServerListPingPacket, err: ReadError) {
    // on 1.4 - 1.5 the client sends an additional 0x01
    // on 1.6, more additional data is sent

    // TODO: short reads between the 0xfe01 and the extra data will result in a loss of data here
    if (buf_consume_byte(buf, 0x01) or_return) && len(buf.data) > 0 {
        plugin_msg_packet_id := buf_read_byte(buf) or_return

        channel_codeunits_len := buf_read_u16(buf) or_return
        channel_bytes := make([]u8, channel_codeunits_len * 2, allocator)
        buf_read_bytes(buf, channel_bytes) or_return
        _remaining_len := buf_read_u16(buf) or_return
        _ = _remaining_len
        protocol_version := buf_read_byte(buf) or_return
        hostname_codeunits_len := buf_read_u16(buf) or_return
        hostname_bytes := make([]u8, hostname_codeunits_len * 2, allocator)
        buf_read_bytes(buf, hostname_bytes) or_return
        port := buf_read_int(buf) or_return

        p.v1_6_extension = LegacyServerListPingV1_6Extension {
            plugin_msg_packet_id = plugin_msg_packet_id,
            channel = Utf16String(channel_bytes),
            protocol_version = protocol_version,
            hostname = Utf16String(hostname_bytes),
            port = port,
        }
    }
    return p, .None
}

read_protocol_version :: proc(buf: ^NetworkBuffer) -> (p: ProtocolVersion, err: ReadError) {
    val := buf_read_var_int(buf) or_return
    protocol_valid := true // TODO: use table in protcol_version.odin
    return ProtocolVersion(val), .None if protocol_valid else .InvalidData
}
