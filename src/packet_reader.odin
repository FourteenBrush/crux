package crux

import "core:log"
import "core:mem"

// Attempts to read a complete packet from the given buffer, this procedure is transactional and will only
// consume bytes when a full packet can be read.
// The only exception to this transactional behavior is when errors other than short reads occur (aka non-recoverable),
// the internal state of the passed buffer will be modified there.
read_serverbound :: proc(b: ^NetworkBuffer, client_state: ClientState, allocator: mem.Allocator) -> (p: ServerBoundPacket, err: ReadError) {
    if buf_consume_byte(b, 0xfe) or_return {
        // NOTE: vanilla client attempts to send a legacy server list ping packet when
        // normal ping times out (30s), additionally older clients send this, which we are supposed to handle
        // TODO: directly kick after FE 01 FA
        return read_legacy_server_list_ping(b, allocator=allocator)
    }

    // early return on short read, no bytes consumed
    length, length_nbytes := buf_peek_var_int(b) or_return
    buf_ensure_readable(b^, length) or_return

    buf_advance_pos_unchecked(b, length_nbytes)
    start_off := b.r_offset
    id := buf_read_var_int(b) or_return

    switch ServerBoundPacketId(id) {
    case .Handshake: // shared with .StatusRequest, LoginStart and ClientInformation, blame the protocol
        
        switch client_state {
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
        case .Configuration:
            return ClientInformationPacket {
                // TODO: unchecked reads
                locale = buf_read_string(b, 16, allocator) or_return,
                view_distance = buf_unchecked_read_byte(b),
                chat_mode = buf_unchecked_read_var_int_enum(b, ChatMode) or_return,
                chat_colors = buf_unchecked_read_bool(b) or_return,
                skin_parts = buf_read_flags(b, SkinParts) or_return,
                main_hand = buf_unchecked_read_var_int_enum(b, MainHand) or_return,
                enable_text_filtering = buf_unchecked_read_bool(b) or_return,
                allow_server_listings = buf_unchecked_read_bool(b) or_return,
                particle_status = buf_unchecked_read_var_int_enum(b, ParticleStatus) or_return,
            }, .None
        case .Transfer:
            return {}, .InvalidData
        case: unreachable()
        }

    case .PingRequest:
        payload := buf_read_long(b) or_return
        return PingRequestPacket { payload }, .None
    case .LoginAcknowledged:
        return LoginAcknowledgedPacket {}, .None
    case .PluginMessage:
        channel := buf_read_identifier(b, allocator) or_return
        payload, _ := mem.alloc_bytes_non_zeroed(int(length) - buf_bytes_consumed_since(b^, start_off), allocator=allocator)
        buf_read_bytes(b, payload[:]) or_return
        return PluginMessagePacket { channel=channel, payload=payload }, .None
    case:
        log.warn("unhandled packet id:", ServerBoundPacketId(id), "kicking with .InvalidData")
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
