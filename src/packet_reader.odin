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
        return _read_legacy_server_list_ping(b, allocator=allocator)
    }

    // early return on short read, no bytes consumed
    // TODO: make _all_ read calls below bypass bounds checking
    length, length_nbytes := buf_peek_var_int(b) or_return
    buf_ensure_readable(b^, length) or_return

    buf_advance_pos_unchecked(b, length_nbytes)
    start_off := b.r_offset
    id := buf_read_var_int(b) or_return
    
    defer if err == .InvalidData {
        log.debug("invalid data for packet id", ServerBoundPacketId(id))
    }

    switch ServerBoundPacketId(id) {
    case .Handshake: // shared with .StatusRequest, LoginStart, ClientInformation and .ConfirmTeleportation, blame the protocol
        
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
            return _read_client_information(b, allocator)
        case .Play:
            teleport_id := buf_read_var_int(b) or_return
            return ConfirmTeleportationPacket { teleport_id=teleport_id }, .None
        case .Transfer:
            return p, .InvalidData
        case: unreachable()
        }

    case .PingRequest:
        payload := buf_read_long(b) or_return
        return PingRequestPacket { payload }, .None
    case .LoginAcknowledged: // shared with .AcknowledgeFinishConfiguration
        #partial switch client_state {
        case .Login: return LoginAcknowledgedPacket {}, .None
        case .Configuration: return AcknowledgeFinishConfigurationPacket {}, .None
        case: return p, .InvalidData
        }
        return LoginAcknowledgedPacket {}, .None
    case .PluginMessage:
        channel := buf_read_identifier(b, allocator) or_return
        payload, _ := mem.alloc_bytes_non_zeroed(int(length) - buf_bytes_consumed_since(b^, start_off), allocator=allocator)
        buf_read_bytes(b, payload[:]) or_return
        return PluginMessagePacket { channel=channel, payload=payload }, .None
    case .KnownPacks:
        count := buf_read_var_int(b) or_return
        known_packs := make([]KnownPack, count, allocator)
        for &pack in known_packs {
            pack.namespace = buf_read_string(b, 32767, allocator) or_return
            pack.id = buf_read_string(b, 32767, allocator) or_return
            pack.version = buf_read_string(b, 32767, allocator) or_return
        }
        return KnownPacksPacket { known_packs }, .None
    case .ClientTickEnd:
        return ClientTickEndPacket {}, .None
    case .SetPlayerRotation:
        yaw := buf_read_f32(b) or_return
        pitch := buf_read_f32(b) or_return
        flags := buf_read_flags(b, PlayerMovementFlags) or_return
        return SetPlayerRotationPacket { yaw=yaw, pitch=pitch, flags=flags }, .None
    case .SetPlayerPosition:
        x := buf_read_f64(b) or_return
        feet_y := buf_read_f64(b) or_return
        z := buf_read_f64(b) or_return
        flags := buf_read_flags(b, PlayerMovementFlags) or_return
        return SetPlayerPositionPacket { x=x, y=feet_y, z=z, flags=flags }, .None
    case .SetPlayerPositionRotation:
        x := buf_read_f64(b) or_return
        feet_y := buf_read_f64(b) or_return
        z := buf_read_f64(b) or_return
        yaw := buf_read_f32(b) or_return
        pitch := buf_read_f32(b) or_return
        flags := buf_read_flags(b, PlayerMovementFlags) or_return
        return SetPlayerPositionRotationPacket { x=x, y=feet_y, z=z, yaw=yaw, pitch=pitch, flags=flags }, .None
    case .SetPlayerMovement:
        flags := buf_read_flags(b, PlayerMovementFlags) or_return
        return SetPlayerMovementPacket { flags=flags }, .None
    case .PlayerLoaded:
        return PlayerLoadedPacket {}, .None
    case .KeepAlivePlay:
        id := buf_read_long(b) or_return
        return KeepAlivePlayPacket { id=id }, .None
    case .SwingArm:
        hand := buf_read_var_int_enum(b, Hand) or_return
        return SwingArmPacket { hand=hand }, .None
    case .PlayerInput:
        flags := buf_read_flags(b, PlayerInputFlags) or_return
        return PlayerInputPacket { flags=flags }, .None
    case .FlightChange:
        flags := buf_read_flags(b, PlayerFlightChangeFlags) or_return
        return PlayerFlightChangePacket { flags=flags }, .None
    case .StoreCookiePlay:
        key := buf_read_identifier(b, allocator) or_return
        payload_len := buf_read_var_int(b) or_return
        payload := mem.alloc_bytes_non_zeroed(int(payload_len), align_of(u8), allocator) or_else panic("OOM")
        buf_read_bytes(b, payload) or_return
        return StoreCookiePlayPacket { key=key, payload=payload }, .None
    case .SetHeldItem:
        slot := buf_read_i16(b) or_return
        return SetHeldItemPacket { slot=slot }, .None
    case .CloseContainer:
        window_id := buf_read_var_int(b) or_return
        return CloseContainerPacket { window_id=window_id }, .None
    case .PlayerCommand:
        entity_id := buf_read_var_int(b) or_return
        action := buf_read_var_int_enum(b, PlayerCommandAction) or_return
        jump_boost := buf_read_var_int(b) or_return
        if jump_boost < 0 || jump_boost > 100 {
            return p, .InvalidData
        }
        return PlayerCommandPacket { entity_id=entity_id, action=action, jump_boost=jump_boost }, .None
    case .PlayerAction:
        status := buf_read_var_int_enum(b, PlayerActionStatus) or_return
        location := buf_read_position(b) or_return
        face := buf_read_byte_enum(b, BlockFace) or_return
        sequence := buf_read_var_int(b) or_return
        return PlayerActionPacket { status=status, location=location, face=face, sequence=sequence }, .None
    case .ChatCommand:
        command := buf_read_string(b, 32767, allocator) or_return
        return ChatCommandPacket { command=command }, .None
    case .ClientInformationPlay:
        return _read_client_information(b, allocator)
    case:
        log.warnf("unhandled packet id: 0x%x for client state", id, client_state)
        return p, .InvalidData
    }
}

@(private="file")
_read_client_information :: proc(buf: ^NetworkBuffer, allocator: mem.Allocator) -> (p: ClientInformationPacket, err: ReadError) {
    return ClientInformationPacket {
        // TODO: unchecked reads
        locale = buf_read_string(buf, 16, allocator) or_return,
        view_distance = buf_unchecked_read_byte(buf),
        chat_mode = buf_unchecked_read_var_int_enum(buf, ChatMode) or_return,
        chat_colors = buf_unchecked_read_bool(buf) or_return,
        skin_parts = buf_read_flags(buf, SkinParts) or_return,
        main_hand = buf_unchecked_read_var_int_enum(buf, MainHand) or_return,
        enable_text_filtering = buf_unchecked_read_bool(buf) or_return,
        allow_server_listings = buf_unchecked_read_bool(buf) or_return,
        particle_status = buf_unchecked_read_var_int_enum(buf, ParticleStatus) or_return,
    }, .None
}

// Reads a legacy server list ping packet, the initial byte 0xfe has already been read.
@(private="file")
_read_legacy_server_list_ping :: proc(buf: ^NetworkBuffer, allocator: mem.Allocator) -> (p: LegacyServerListPingPacket, err: ReadError) {
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
