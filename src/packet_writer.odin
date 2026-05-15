package crux

import "base:runtime"
import "core:log"
import "core:encoding/json"

import "lib:tracy"

import "src:reactor"

// TODO: propagate errors and close connection
enqueue_packet :: proc(io_ctx: ^reactor.IOContext, client_conn: ^ClientConnection, packet: ClientBoundPacket) {
    tracy.Zone()
    log.log(LOG_LEVEL_OUTBOUND, "Sending packet", packet)

    _serialize_clientbound(packet, &client_conn.tx_buf)
    
    // freed by network worker after receiving write completion
    outb := make([]u8, buf_length(client_conn.tx_buf), client_conn.packet_scratch_alloc)
    read_err := buf_copy_into(&client_conn.tx_buf, outb)
    assert(read_err == .None, "invariant, copied full length")

    submission_ok := reactor.submit_write_copy(io_ctx, client_conn.socket, outb)
    assert(submission_ok, "TODO: submission errors")
    buf_advance_pos_unchecked(&client_conn.tx_buf, len(outb))
}

@(private="file")
_serialize_clientbound :: proc(packet: ClientBoundPacket, outb: ^NetworkBuffer) -> WriteError {
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
        // TODO: serialize SNBT
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
    case PluginMessagePacket:
        buf_write_identifier(outb, packet.channel)
        buf_write_bytes(outb, packet.payload)
    case DisconnectConfigurationPacket:
        werr := serialize_text_component(outb, packet.reason)
        assert(werr == nil, "max string length exceeded") // TODO
    case FinishConfigurationPacket:
        // no fields
    case RegistryDataPacket:
        #partial switch packet in packet {
        case DimensionTypeRegistry: _serialize_dimension_type_registry(outb, packet)
        }
    case LoginPacket:
        buf_write_i32(outb, packet.entity_id)
        buf_write_byte(outb, u8(packet.is_hardcore))
        buf_write_var_int(outb, VarInt(len(packet.dimension_names)))
        for dimension in packet.dimension_names {
            buf_write_identifier(outb, dimension)
        }
        buf_write_var_int(outb, packet.max_players)
        buf_write_var_int(outb, packet.view_distance)
        buf_write_var_int(outb, packet.simulation_distance)
        buf_write_byte(outb, u8(packet.reduced_debug_info))
        buf_write_byte(outb, u8(packet.enable_respawn_screen))
        buf_write_byte(outb, u8(packet.do_limited_crafting))
        buf_write_var_int(outb, packet.dimension_type)
        buf_write_identifier(outb, packet.dimension_name)
        buf_write_long(outb, packet.hashed_seed)
        buf_write_byte(outb, u8(packet.gamemode))
        buf_write_byte(outb, u8(packet.prev_gamemode.? or_else Gamemode(-1))) // TODO: ensure -1 is correctly written
        buf_write_byte(outb, u8(packet.is_debug))
        buf_write_byte(outb, u8(packet.is_flat))
        if death_location, ok := packet.death_location.?; ok {
            buf_write_byte(outb, 1)
            buf_write_identifier(outb, death_location.dimension_name)
            buf_write_u64(outb, transmute(u64)death_location.location)
        } else {
            buf_write_byte(outb, 0)
        }
        buf_write_var_int(outb, packet.portal_cooldown)
        buf_write_var_int(outb, packet.sea_level)
        buf_write_byte(outb, u8(packet.enforces_secure_chat))
    }
    return .None
}

@(private="file")
_serialize_dimension_type_registry :: proc(outb: ^NetworkBuffer, reg: DimensionTypeRegistry) -> WriteError {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    
    buf_write_identifier(outb, Identifier("minecraft:dimension_type"))
    buf_write_var_int(outb, VarInt(len(reg.entries)))
    
    writer := create_nbt_writer(outb, context.temp_allocator, network_nbt=true)
    
    for entry in reg.entries {
        buf_write_identifier(outb, entry.id)
        
        entry, present := entry.data.?
        buf_write_byte(outb, u8(present))
        if !present do continue
        
        nbt_write_compound_start(&writer)
        defer nbt_write_compound_end(&writer)
        
        nbt_write_named_double(&writer, "coordinate_scale", entry.coordinate_scale) or_return
        nbt_write_named_bool(&writer, "has_skylight", entry.has_skylight) or_return
        nbt_write_named_bool(&writer, "has_ceiling", entry.has_ceiling) or_return
        nbt_write_named_bool(&writer, "has_ender_dragon_fight", entry.has_ender_dragon_fight) or_return
        nbt_write_named_float(&writer, "ambient_light", entry.ambient_light) or_return
        nbt_write_named_bool(&writer, "has_fixed_time", entry.has_fixed_time) or_return
        nbt_write_named_int(&writer, "monster_spawn_block_light_limit", i32(entry.monster_spawn_block_light_limit)) or_return
        nbt_write_named_int(&writer, "monster_spawn_light_level", i32(entry.monster_spawn_light_level)) or_return
        nbt_write_named_int(&writer, "logical_height", i32(entry.logical_height)) or_return
        nbt_write_named_int(&writer, "min_y", i32(entry.min_y)) or_return
        nbt_write_named_int(&writer, "height", i32(entry.height)) or_return
        nbt_write_named_string(&writer, "infiniburn", string(entry.infiniburn)) or_return
        nbt_write_named_string(&writer, "skybox", skybox_to_string(entry.skybox)) or_return
        nbt_write_named_string(&writer, "cardinal_light", cardinal_light_to_string(entry.cardinal_light)) or_return
        nbt_write_named_compound_start(&writer, "attributes") or_return
        // TODO: environment attributes
        nbt_write_compound_end(&writer)
        if default_clock, ok := entry.default_clock.?; ok {
            nbt_write_named_string(&writer, "default_clock", string(default_clock)) or_return
        }
        if len(entry.timelines) == 1 {
            nbt_write_named_string(&writer, "timelines", string(entry.timelines[0])) or_return
        } else {
            nbt_write_named_list_start(&writer, "timelines", .String, len(entry.timelines)) or_return
            for timeline in entry.timelines {
                nbt_write_string(&writer, string(timeline)) or_return
            }
        }
    }
    return .None
}