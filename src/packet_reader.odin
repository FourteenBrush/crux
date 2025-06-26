package crux

import "core:log"
import "core:mem"

read_serverbound :: proc(b: ^NetworkBuffer, allocator: mem.Allocator) -> (p: ServerboundPacket, err: ReadError) {
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

    #partial switch PacketId(id) {
    case .Handshake: // shared with .StatusRequest, blame the protocol
        if length == 1 /* only id */ {
            return StatusRequestPacket {}, .None
        }

        // handshake
        protocol_version := read_protocol_version(b) or_return
        server_addr := buf_read_string(b, allocator) or_return
        server_port := buf_read_u16(b) or_return
        next_state := read_client_state(b, min=.Status) or_return

        return HandshakePacket {
            protocol_version = protocol_version,
            server_addr = server_addr,
            server_port = server_port,
            intent = next_state,
        }, .None
    case:
        log.warn("unhandled packet id:", PacketId(id))
        return p, .InvalidData
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
        buf_read_nbytes(buf, channel_bytes) or_return
        _remaining_len := buf_read_u16(buf) or_return
        protocol_version := buf_read_byte(buf) or_return
        hostname_codeunits_len := buf_read_u16(buf) or_return
        hostname_bytes := make([]u8, hostname_codeunits_len * 2, allocator)
        buf_read_nbytes(buf, hostname_bytes) or_return
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

// TODO: enum lookups with fast path indicated by intrinsics.type_enum_is_contiguous

read_protocol_version :: proc(buf: ^NetworkBuffer) -> (p: ProtocolVersion, err: ReadError) {
    val := buf_read_var_int(buf) or_return
    protocol_valid := true // TODO: use table in protcol_version.odin
    return ProtocolVersion(val), .None if protocol_valid else .InvalidData
}

read_client_state :: proc(buf: ^NetworkBuffer, min: ClientState) -> (c: ClientState, err: ReadError) {
    val := buf_read_var_int(buf) or_return
    if ClientState(val) < min || ClientState(val) > max(ClientState) {
        return c, .InvalidData
    }
    return ClientState(val), .None
}
