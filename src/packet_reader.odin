#+vet explicit-allocators
package crux

import "core:log"
import "core:mem"
import "core:slice"
import "core:compress/deflate"

import "src:items"

@(private="file")
MAX_COMPRESSED_DATA_LEN :: 8388608 // 2 ^ 23

// Attempts to read a complete packet from the given buffer, this procedure is transactional and will only
// consume bytes when a full packet can be read.
// The only exception to this transactional behavior is when errors other than short reads occur (aka non-recoverable),
// the internal state of the passed buffer will be modified there.
@(private, require_results)
_deserialize_serverbound :: proc(
    buf: ^NetworkBuffer,
    client_state: ClientState,
    compression_threshold: Maybe(i32),
    allocator: mem.Allocator,
) -> (
    packet: ServerBoundPacket,
    err: ReadError,
) {
    when ODIN_DEBUG {
        orig_len := buf_length(buf^)
        defer if err == .ShortRead {
            assert(buf_length(buf^) == orig_len, ".ShortRead errors must not consume bytes, this is a bug")
        }
    }

    compression_threshold, uses_compressed_format := compression_threshold.?
    if !uses_compressed_format || compression_threshold < 0 {
        return _deserialize_serverbound_packet(buf, client_state, allocator)
    }

    // expect compressed packet format
    packet_len, packet_len_nbytes := buf_peek_var_int(buf) or_return
    if packet_len < 2 {
        // we must at least have a Data Length and a Packet Id
        return packet, .InvalidData
    }
    buf_ensure_readable(buf^, packet_len_nbytes + int(packet_len)) or_return
    buf_advance_pos_unchecked(buf, packet_len_nbytes)

    // data_len cannot hold 0xfe here (start of legacy server list ping), as compression
    // could have only been enabled after
    uncompressed_data_len, uncompressed_data_len_nbytes := buf_unchecked_read_var_int_ex(buf) or_return
    if uncompressed_data_len == 0 {
        // no compression in use, compute packet length from total length - 1 (for VarInt(0) nr of bytes)
        length := int(packet_len) - uncompressed_data_len_nbytes
        return _deserialize_serverbound_id_and_payload(buf, client_state, allocator, length)
    }
    
    // actually stores compressed data, data_len represents uncompressed id and payload length
    // vanilla server rejects compressed packets smaller than compression threshold but accepts
    // uncompressed packets exceeding the threshold
    if uncompressed_data_len > MAX_COMPRESSED_DATA_LEN || i32(uncompressed_data_len) < compression_threshold {
        return packet, .InvalidData
    }
    compressed_data_len := int(packet_len) - uncompressed_data_len_nbytes
    if buf_length(buf^) < int(compressed_data_len) || compressed_data_len < 0 {
        log.debugf("length error: buf length=%d, compressed_data_len=%d, packet_len=%d, uncompressed_data_len_nbytes=%d", buf_length(buf^),
            compressed_data_len, packet_len, uncompressed_data_len_nbytes)
        return packet, .InvalidData
    }
    
    compressed_id_and_payload := make([]u8, compressed_data_len, context.temp_allocator)
    assert(buf_read_bytes(buf, compressed_id_and_payload) == .None, "unexpected short read")
    id_and_payload, decompression_err := _decompress_data(
        compressed_id_and_payload,
        expected_output_size=int(uncompressed_data_len),
        buf_allocator=context.temp_allocator,
    )
    if decompression_err != nil {
        log.debug("decompression error:", decompression_err)
        // log.debugf("packet_len=%d, compressed_data_len=%d, compressed data dump: %2x", packet_len, compressed_data_len, compressed_id_and_payload)
        return packet, .InvalidData
    }

    if len(id_and_payload) != int(uncompressed_data_len) {
        // uncompressed data len does not match uncompressed data len stored in packet
        return packet, .InvalidData
    }

    decompressed_buf := NetworkBuffer { data = slice.into_dynamic(id_and_payload) }
    return _deserialize_serverbound_id_and_payload(&decompressed_buf, client_state, allocator, int(uncompressed_data_len))
}

@(private="file")
_decompress_data :: proc(data: []u8, expected_output_size: int, buf_allocator: mem.Allocator) -> (decompressed: []u8, err: deflate.Error) {
    // a reserve() is performed on this buffer 
    out: [dynamic]u8
    out.allocator = buf_allocator
    err = deflate.inflate_zlib_from_bytes(&out, data, expected_output_size=expected_output_size, allocator=buf_allocator)
    return out[:], err
}

// Attempts to parse a serverbound packet from a buffer containing the length, packet id and payload
// (all uncompressed).
@(private="file", require_results)
_deserialize_serverbound_packet :: proc(
    buf: ^NetworkBuffer,
    client_state: ClientState,
    allocator: mem.Allocator,
) -> (
    packet: ServerBoundPacket,
    err: ReadError,
) {
    if buf_consume_byte(buf, 0xfe) or_return {
        // NOTE: vanilla client attempts to send a legacy server list ping packet when
        // normal ping times out (30s), additionally older clients send this, which we are supposed to handle
        // TODO: directly kick after FE 01 FA
        return _read_legacy_server_list_ping(buf, allocator=allocator)
    }

    // early return on short read, no bytes consumed
    length, length_nbytes := buf_peek_var_int(buf) or_return
    buf_ensure_readable(buf^, length) or_return

    buf_advance_pos_unchecked(buf, length_nbytes)

    return _deserialize_serverbound_id_and_payload(buf, client_state, allocator, int(length))
}

// Attempts to parse a serverbound packet from the given buffer, which stores the uncompressed
// packet id and payload.
@(private="file", require_results)
_deserialize_serverbound_id_and_payload :: proc(
    buf: ^NetworkBuffer,
    client_state: ClientState,
    allocator: mem.Allocator,
    id_and_payload_length: int,
) -> (
    packet: ServerBoundPacket,
    err: ReadError,
) {
    start_off := buf.r_offset
    id := buf_read_var_int(buf) or_return
    
    defer if err == .InvalidData {
        log.debug("invalid data for packet id", ServerBoundPacketId(id))
    }

    // TODO: make _all_ read calls below bypass bounds checking
    switch ServerBoundPacketId(id) {
    case .Handshake: // shared with .StatusRequest, LoginStart, ClientInformation and .ConfirmTeleportation, blame the protocol
        
        switch client_state {
        case .Handshake:
            return HandshakePacket {
                protocol_version = _read_protocol_version(buf) or_return,
                server_addr = buf_read_string(buf, 255, allocator) or_return,
                server_port = buf_read_u16(buf) or_return,
                intent = buf_read_var_int_enum(buf, HandshakeIntent) or_return,
            }, .None
        case .Status:
            return StatusRequestPacket {}, .None
        case .Login:
            username := buf_read_string(buf, 16, allocator) or_return
            uuid := buf_read_uuid(buf) or_return
            return LoginStartPacket { username, uuid }, .None
        case .Configuration:
            return _read_client_information(buf, allocator)
        case .Play:
            teleport_id := buf_read_var_int(buf) or_return
            return ConfirmTeleportationPacket { teleport_id=teleport_id }, .None
        case .Transfer:
            return packet, .InvalidData
        case: unreachable()
        }

    case .PingRequest:
        payload := buf_read_long(buf) or_return
        return PingRequestPacket { payload }, .None
    case .LoginAcknowledged: // shared with .AcknowledgeFinishConfiguration
        #partial switch client_state {
        case .Login: return LoginAcknowledgedPacket {}, .None
        case .Configuration: return AcknowledgeFinishConfigurationPacket {}, .None
        case: return packet, .InvalidData
        }
        return LoginAcknowledgedPacket {}, .None
    case .PluginMessage:
        channel := buf_read_identifier(buf, allocator) or_return
        payload_len := id_and_payload_length - (buf.r_offset - start_off)
        payload, _ := mem.alloc_bytes_non_zeroed(payload_len, alignment=align_of(u8), allocator=allocator)
        buf_read_bytes(buf, payload[:]) or_return
        return PluginMessagePacket { channel=channel, payload=payload }, .None
    case .KnownPacks:
        count := buf_read_var_int(buf) or_return
        known_packs := make([]KnownPack, count, allocator)
        for &pack in known_packs {
            pack.namespace = buf_read_string(buf, 32767, allocator) or_return
            pack.id = buf_read_string(buf, 32767, allocator) or_return
            pack.version = buf_read_string(buf, 32767, allocator) or_return
        }
        return KnownPacksPacket { known_packs }, .None
    case .KeepAliveConfiguration:
        id := buf_read_long(buf) or_return
        return KeepAliveConfigurationPacket { id=id }, .None
    case .ClientTickEnd:
        return ClientTickEndPacket {}, .None
    case .SetPlayerRotation:
        yaw := buf_read_f32(buf) or_return
        pitch := buf_read_f32(buf) or_return
        flags := buf_read_flags(buf, PlayerMovementFlags) or_return
        return SetPlayerRotationPacket { yaw=yaw, pitch=pitch, flags=flags }, .None
    case .SetPlayerPosition:
        x := buf_read_f64(buf) or_return
        feet_y := buf_read_f64(buf) or_return
        z := buf_read_f64(buf) or_return
        flags := buf_read_flags(buf, PlayerMovementFlags) or_return
        return SetPlayerPositionPacket { x=x, y=feet_y, z=z, flags=flags }, .None
    case .SetPlayerPositionRotation:
        x := buf_read_f64(buf) or_return
        feet_y := buf_read_f64(buf) or_return
        z := buf_read_f64(buf) or_return
        yaw := buf_read_f32(buf) or_return
        pitch := buf_read_f32(buf) or_return
        flags := buf_read_flags(buf, PlayerMovementFlags) or_return
        return SetPlayerPositionRotationPacket { x=x, y=feet_y, z=z, yaw=yaw, pitch=pitch, flags=flags }, .None
    case .SetPlayerMovement:
        flags := buf_read_flags(buf, PlayerMovementFlags) or_return
        return SetPlayerMovementPacket { flags=flags }, .None
    case .PlayerLoaded:
        return PlayerLoadedPacket {}, .None
    case .KeepAlivePlay:
        id := buf_read_long(buf) or_return
        return KeepAlivePlayPacket { id=id }, .None
    case .SwingArm:
        hand := buf_read_var_int_enum(buf, Hand) or_return
        return SwingArmPacket { hand=hand }, .None
    case .PlayerInput:
        flags := buf_read_flags(buf, PlayerInputFlags) or_return
        return PlayerInputPacket { flags=flags }, .None
    case .FlightChange:
        flags := buf_read_flags(buf, PlayerFlightChangeFlags) or_return
        return PlayerFlightChangePacket { flags=flags }, .None
    case .StoreCookiePlay:
        key := buf_read_identifier(buf, allocator) or_return
        payload_len := buf_read_var_int(buf) or_return
        payload := mem.alloc_bytes_non_zeroed(int(payload_len), align_of(u8), allocator) or_else panic("OOM")
        buf_read_bytes(buf, payload) or_return
        return StoreCookiePlayPacket { key=key, payload=payload }, .None
    case .SetHeldItem:
        slot := buf_read_i16(buf) or_return
        return SetHeldItemPacket { slot=slot }, .None
    case .CloseContainer:
        window_id := buf_read_var_int(buf) or_return
        return CloseContainerPacket { window_id=window_id }, .None
    case .PlayerCommand:
        entity_id := buf_read_var_int(buf) or_return
        action := buf_read_var_int_enum(buf, PlayerCommandAction) or_return
        jump_boost := buf_read_var_int(buf) or_return
        if jump_boost < 0 || jump_boost > 100 {
            return packet, .InvalidData
        }
        return PlayerCommandPacket { entity_id=entity_id, action=action, jump_boost=jump_boost }, .None
    case .PlayerAction:
        status := buf_read_var_int_enum(buf, PlayerActionStatus) or_return
        location := buf_read_position(buf) or_return
        face := buf_read_byte_enum(buf, BlockFace) or_return
        sequence := buf_read_var_int(buf) or_return
        return PlayerActionPacket { status=status, location=location, face=face, sequence=sequence }, .None
    case .ChatCommand:
        command := buf_read_string(buf, 32767, allocator) or_return
        return ChatCommandPacket { command=command }, .None
    case .ClientInformationPlay:
        return _read_client_information(buf, allocator)
    case .ClickContainer:
        packet = ClickContainerPacket {
            window_id = buf_read_var_int(buf) or_return,
            state_id = buf_read_var_int(buf) or_return,
            slot = buf_read_i16(buf) or_return,
            button = cast(i8)buf_read_byte(buf) or_return,
            mode = buf_read_var_int(buf) or_return,
            changed_slots = make([]ChangedSlot, buf_read_var_int(buf) or_return, allocator),
        }
        packet_ := &packet.(ClickContainerPacket)
        for &changed_slot in packet_.changed_slots {
            slot_nr := buf_read_i16(buf) or_return
            slot_data := _read_hashed_slot(buf, allocator) or_return
            changed_slot = ChangedSlot { slot_nr=slot_nr, slot_data=slot_data }
        }
        packet_.carried_item = _read_hashed_slot(buf, allocator) or_return
        return packet, .None
    case .UseItemOn:
        hand := buf_read_var_int_enum(buf, Hand) or_return
        loc := buf_read_position(buf) or_return
        face := buf_read_var_int_enum(buf, BlockFace) or_return
        cursor_pos := [3]f32 {
            0 = buf_read_f32(buf) or_return,
            1 = buf_read_f32(buf) or_return,
            2 = buf_read_f32(buf) or_return,
        }
        inside_block := buf_read_bool(buf) or_return
        world_border_hit := buf_read_bool(buf) or_return
        sequence := buf_read_var_int(buf) or_return
        return UseItemOnPacket {
            hand=hand,
            loc=loc,
            face=face,
            cursor_pos=cursor_pos,
            inside_block=inside_block,
            world_border_hit=world_border_hit,
            sequence=sequence,
        }, .None
    case .UseItem:
        hand := buf_read_var_int_enum(buf, Hand) or_return
        sequence := buf_read_var_int(buf) or_return
        yaw := buf_read_f32(buf) or_return
        pitch := buf_read_f32(buf) or_return
        return UseItemPacket { hand=hand, sequence=sequence, yaw=yaw, pitch=pitch }, .None
    case:
        log.warnf("unhandled packet id: 0x%x for client state %v", id, client_state)
        return packet, .InvalidData
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

@(private="file")
_read_hashed_slot :: proc(buf: ^NetworkBuffer, allocator: mem.Allocator) -> (_slot: Maybe(HashedSlot), err: ReadError) {
    if (buf_read_bool(buf) or_return) == false {
        return nil, .None
    }
    slot := HashedSlot {
        item_id = buf_read_var_int(buf) or_return,
        item_count = buf_read_var_int(buf) or_return,
    }

    slot.components_to_add = make([]SlotComponentHash, buf_read_var_int(buf) or_return, allocator)
    for &comp in slot.components_to_add {
        comp.type = buf_read_var_int_enum(buf, items.DataComponentType) or_return
        comp.data_hash = cast(i32)buf_read_int(buf) or_return
    }

    slot.components_to_remove = make([]items.DataComponentType, buf_read_var_int(buf) or_return, allocator)
    for &comp in slot.components_to_remove {
        comp = buf_read_var_int_enum(buf, items.DataComponentType) or_return
    }
    
    return slot, .None
}

@(private="file")
_read_protocol_version :: proc(buf: ^NetworkBuffer) -> (p: ProtocolVersion, err: ReadError) {
    val := buf_read_var_int(buf) or_return
    protocol_valid := true // TODO: use table in protcol_version.odin
    return ProtocolVersion(val), .None if protocol_valid else .InvalidData
}
