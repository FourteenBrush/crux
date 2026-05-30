package crux

import "base:runtime"
import "core:encoding/json"
import "base:intrinsics"

@(private="file")
LOG2 :: intrinsics.constant_log2

@(private)
_serialize_clientbound :: proc(outb: ^NetworkBuffer, packet: ClientBoundPacket, descriptor: ClientBoundPacketDescriptor) -> WriteError {
    initial_len := buf_length(outb^)
    begin_payload_mark := buf_emit_write_mark(outb^)
    defer {
        // FIXME: can we instead of moving data, reserve space for a (unnecessarily long) encoded VarInt
        payload_len := buf_length(outb^) - initial_len
        err := buf_write_var_int_at(outb, begin_payload_mark, VarInt(payload_len))
        assert(err == .None, "invariant, mark could not have become invalid")
    }

    buf_write_var_int(outb, VarInt(descriptor.packet_id))

    switch packet in packet {
    case StatusResponsePacket:
        // json serializer does not return allocator errors, so there should be no reason this fails
        bytes := json.marshal(packet, allocator=context.temp_allocator) or_else panic("error serializing status response")
        werr := buf_write_string(outb, string(bytes)) // copied
        assert(werr == .None, "max string length exceeded") // TODO
    case PongResponsePacket:
        buf_write_long(outb, packet.payload)
    case LoginSuccessPacket:
        buf_write_uuid(outb, packet.game_profile.uuid)
        _ = buf_write_string(outb, packet.game_profile.username)
        // properties
        // TODO: fix whatever this is
        buf_write_var_int(outb, VarInt(1)) // 1 property
        _ = buf_write_string(outb, packet.game_profile.name)
        _ = buf_write_string(outb, packet.game_profile.value)
        
        // optional signature
        buf_write_byte(outb, 1 if packet.game_profile.signature != nil else 0)
        if signature, ok := packet.game_profile.signature.?; ok {
            _ = buf_write_string(outb, signature)
        }
    case DisconnectLoginPacket:
        json := serialize_text_component(packet.reason, context.temp_allocator)
        werr := buf_write_string(outb, string(json))
        assert(werr == nil, "error serializing disconnect packet")
    case PluginMessagePacket:
        buf_write_identifier(outb, packet.channel)
        buf_write_bytes(outb, packet.payload)
    case DisconnectConfigurationPacket:
        serialize_text_component(outb, packet.reason) or_return
    case KnownPacksPacket:
        buf_write_var_int(outb, VarInt(len(packet.known_packs)))
        for pack in packet.known_packs {
            buf_write_string(outb, pack.namespace) or_return
            buf_write_string(outb, pack.id) or_return
            buf_write_string(outb, pack.version) or_return
        }
    case RegistryDataPacket:
    switch reg in packet {
    case DimensionTypeRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:dimension_type"), _serialize_dimension_type_registry_entry)
    case CatVariantRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:cat_variant"), _serialize_cat_variant_registry_entry)
    case ChickenVariantRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:chicken_variant"), _serialize_chicken_variant_registry_entry)
    case CowVariantRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:cow_variant"), _serialize_cow_variant_registry_entry)
    case FrogVariantRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:frog_variant"), _serialize_mob_registry_entry)
    case PigVariantRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:pig_variant"), _serialize_pig_variant_registry_entry)
    case WolfVariantRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:wolf_variant"), _serialize_wolf_variant_registry_entry)
    case WolfSoundVariantRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:wolf_sound_variant"), _serialize_wolf_sound_variant_registry_entry)
    case PaintingVariantRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:painting_variant"), _serialize_painting_variant_registry_entry)
    case DamageTypeRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:damage_type"), _serialize_damage_type_registry_entry)
    case BiomeRegistry:
        return _serialize_registry(outb, reg, Identifier("minecraft:worldgen/biome"), _serialize_biome_registry_entry)
    }
    case FinishConfigurationPacket:
        // no fields
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
        buf_write_byte(outb, u8(packet.prev_gamemode.? or_else GameMode(-1))) // TODO: ensure -1 is correctly written
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
    case DisconnectPlayPacket:
        serialize_text_component(outb, packet.reason) or_return
    case SynchronizePlayerPositionPacket:
        buf_write_var_int(outb, packet.teleport_id)
        buf_write_f64(outb, packet.x)
        buf_write_f64(outb, packet.y)
        buf_write_f64(outb, packet.z)
        buf_write_f64(outb, packet.velocity_x)
        buf_write_f64(outb, packet.velocity_y)
        buf_write_f64(outb, packet.velocity_z)
        buf_write_f32(outb, packet.yaw)
        buf_write_f32(outb, packet.pitch)
        buf_write_u32(outb, transmute(u32)packet.flags)
    case PlayerInfoUpdatePacket:
        PlayerInfoUpdateActions :: bit_set[PlayerInfoUpdateAction; u8]
        PlayerInfoUpdateAction :: enum {
            AddPlayer          = LOG2(0x01),
            InitializeChat     = LOG2(0x02),
            UpdateGameMode     = LOG2(0x04),
            UpdateListed       = LOG2(0x08),
            UpdateLatency      = LOG2(0x10),
            UpdateDisplayName  = LOG2(0x20),
            UpdateListPriority = LOG2(0x40),
            UpdateHat          = LOG2(0x80),
        }
        assert(len(packet.players) > 0, "zero length packet entries")
        actions_mask: PlayerInfoUpdateActions
        // compute used actions mask for players[0], ensure other entries use the same actions
        assert(len(packet.players[0].actions) > 0, "zero length player info update actions")
        for action in packet.players[0].actions {
            switch action in action {
            case PlayerInfoUpdateActionAddPlayer: actions_mask += {.AddPlayer}
            case PlayerInfoUpdateActionUpdateGameMode: actions_mask += {.UpdateGameMode}
            case PlayerInfoUpdateActionUpdateListed: actions_mask += {.UpdateListed}
            }
        }
        for player in packet.players {
            for action in player.actions {
                switch action in action {
                case PlayerInfoUpdateActionAddPlayer: assert(.AddPlayer in actions_mask, "mismatched action sets")
                case PlayerInfoUpdateActionUpdateGameMode: assert(.UpdateGameMode in actions_mask, "mismatched action sets")
                case PlayerInfoUpdateActionUpdateListed: assert(.UpdateListed in actions_mask, "mismatched action sets")
                }
            }
        }
        // serialize
        buf_write_byte(outb, transmute(u8)actions_mask)
        buf_write_var_int(outb, VarInt(len(packet.players)))
        for player in packet.players {
            buf_write_uuid(outb, player.uuid)
            for action in player.actions {
                switch action in action {
                case PlayerInfoUpdateActionAddPlayer:
                    buf_write_string(outb, action.username) or_return
                    buf_write_var_int(outb, VarInt(len(action.properties)))
                    for prop in action.properties {
                        buf_write_string(outb, prop.name) or_return
                        buf_write_string(outb, prop.value) or_return
                        if signature, ok := prop.signature.?; ok {
                            buf_write_byte(outb, 1)
                            buf_write_string(outb, signature) or_return
                        } else {
                            buf_write_byte(outb, 0)
                        }
                    }
                case PlayerInfoUpdateActionUpdateGameMode:
                    buf_write_var_int(outb, VarInt(action.new_mode))
                case PlayerInfoUpdateActionUpdateListed:
                    buf_write_byte(outb, u8(action.listed))
                }
            }
        }
    case GameEventPacket:
        // packet structure: u8 followed by f32
        GameEventPacketId :: enum u8 {
            NoRespawnBlockAvailable = 0,
            BeginRaining                = 1,
            EndRaining                  = 2,
            ChangeGameMode              = 3,
            WinGame                     = 4,
            DemoEvent                   = 5,
            ArrowHitPlayer              = 6,
            RainLevelChange             = 7,
            ThunderLevelChange          = 8,
            PlayPufferfishStingSound    = 9,
            PlayElderGuardianAppearance = 10,
            EnableRespawnScreen         = 11,
            SetLimitedCrafting          = 12,
            StartWaitingForChunks       = 13,
        }
        
        event_id: GameEventPacketId
        data := f32(0)
        
        switch event in packet {
        case NoRespawnBlockAvailable:
            event_id = .NoRespawnBlockAvailable
        case BeginRaining:
            event_id = .BeginRaining
        case EndRaining:
            event_id = .EndRaining
        case ChangeGameMode:
            event_id = .ChangeGameMode
            data = f32(event.new_mode)
        case WinGame:
            event_id = .WinGame
            data = f32(event)
        case DemoEvent:
            event_id = .DemoEvent
            data = f32(event)
        case ArrowHitPlayer:
            event_id = .ArrowHitPlayer
        case RainLevelChange:
            event_id = .RainLevelChange
            data = f32(event.level)
        case ThunderLevelChange:
            event_id = .ThunderLevelChange
            data = f32(event.level)
        case PlayPufferfishStingSound:
            event_id = .PlayPufferfishStingSound
        case PlayElderGuardianAppearance:
            event_id = .PlayElderGuardianAppearance
        case EnableRespawnScreen:
            event_id = .EnableRespawnScreen
            data = f32(event)
        case SetLimitedCrafting:
            event_id = .SetLimitedCrafting
            data = f32(event)
        case StartWaitingForChunks:
            event_id = .StartWaitingForChunks
        }
        
        buf_write_byte(outb, u8(event_id))
        buf_write_f32(outb, data)
    case PlayerAbilitiesPacket:
        buf_write_byte(outb, transmute(u8)packet.flags)
        buf_write_f32(outb, packet.flying_speed)
        buf_write_f32(outb, packet.fov_modifier)
    case KeepAlivePlayPacket:
        buf_write_long(outb, packet.id)
    case SetCenterChunkPacket:
        buf_write_var_int(outb, packet.chunk_x)
        buf_write_var_int(outb, packet.chunk_z)
    case ChunkDataPacket:
        buf_write_i32(outb, packet.chunk_x)
        buf_write_i32(outb, packet.chunk_z)
        // heightmaps array:
        buf_write_var_int(outb, VarInt(0))
        
        for section in packet.sections {
            buf_write_i16(outb, section.block_count)
            serialize_paletted_container(outb, section.block_states)
            serialize_paletted_container(outb, section.biomes)
        }
        // block entities:
        // buf_write_var_int(outb, VarInt(0))
        // TODO: write heightmap, data, block entities and light data
    }
    return .None
}

@(private="file", require_results)
_serialize_registry :: proc(
    outb: ^NetworkBuffer,
    reg: Registry($E),
    registry_id: Identifier,
    serialize_entry: proc(^NBTWriter, E) -> WriteError,
) -> WriteError {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    
    buf_write_identifier(outb, registry_id)
    buf_write_var_int(outb, VarInt(len(reg.entries)))
    
    writer := create_nbt_writer(outb, context.temp_allocator, network_nbt=true)
    
    for entry in reg.entries {
        buf_write_identifier(outb, entry.id)
        
        entry, present := entry.data.?
        buf_write_byte(outb, u8(present))
        if !present do continue
        
        nbt_write_compound_start(&writer)
        defer nbt_write_compound_end(&writer)
        
        serialize_entry(&writer, entry) or_return
    }
    return .None
}

// TODO: fix encoding, getting a
// Caused by: java.io.EOFException: fieldSize is too long! Length is 24419, but maximum is 43
@(private="file", require_results)
_serialize_dimension_type_registry_entry :: proc(writer: ^NBTWriter, entry: DimensionType) -> WriteError {
    nbt_write_named_double(writer, "coordinate_scale", entry.coordinate_scale) or_return
    nbt_write_named_bool(writer, "has_skylight", entry.has_skylight) or_return
    nbt_write_named_bool(writer, "has_ceiling", entry.has_ceiling) or_return
    nbt_write_named_bool(writer, "has_ender_dragon_fight", entry.has_ender_dragon_fight) or_return
    nbt_write_named_float(writer, "ambient_light", entry.ambient_light) or_return
    nbt_write_named_bool(writer, "has_fixed_time", entry.has_fixed_time) or_return
    nbt_write_named_int(writer, "monster_spawn_block_light_limit", i32(entry.monster_spawn_block_light_limit)) or_return
    nbt_write_named_int(writer, "monster_spawn_light_level", i32(entry.monster_spawn_light_level)) or_return
    nbt_write_named_int(writer, "logical_height", i32(entry.logical_height)) or_return
    nbt_write_named_int(writer, "min_y", i32(entry.min_y)) or_return
    nbt_write_named_int(writer, "height", i32(entry.height)) or_return
    nbt_write_named_string(writer, "infiniburn", entry.infiniburn) or_return
    nbt_write_named_string(writer, "skybox", skybox_to_string(entry.skybox)) or_return
    nbt_write_named_string(writer, "cardinal_light", cardinal_light_to_string(entry.cardinal_light)) or_return
    nbt_write_named_compound_start(writer, "attributes") or_return
    // TODO: environment attributes
    nbt_write_compound_end(writer)
    if default_clock, ok := entry.default_clock.?; ok {
        nbt_write_named_string(writer, "default_clock", string(default_clock)) or_return
    }
    if len(entry.timelines) == 1 {
        nbt_write_named_string(writer, "timelines", string(entry.timelines[0])) or_return
    } else {
        nbt_write_named_list_start(writer, "timelines", .String, len(entry.timelines)) or_return
        for timeline in entry.timelines {
            nbt_write_string(writer, string(timeline)) or_return
        }
    }
    return .None
}

@(private="file", require_results)
_serialize_cat_variant_registry_entry :: proc(writer: ^NBTWriter, entry: CatVariant) -> WriteError {
    _serialize_mob_registry_entry(writer, entry) or_return
    nbt_write_named_string(writer, "baby_asset_id", entry.baby_asset_id) or_return
    return .None
}

@(private="file", require_results)
_serialize_chicken_variant_registry_entry :: proc(writer: ^NBTWriter, entry: ChickenVariant) -> WriteError {
    _serialize_mob_registry_entry(writer, entry) or_return
    nbt_write_named_string(writer, "baby_asset_id", entry.baby_asset_id) or_return
    nbt_write_named_string(writer, "model", "cold" if entry.model == .Cold else "normal") or_return
    return .None
}

@(private="file", require_results)
_serialize_cow_variant_registry_entry :: proc(writer: ^NBTWriter, entry: CowVariant) -> WriteError {
    _serialize_mob_registry_entry(writer, entry) or_return
    nbt_write_named_string(writer, "baby_asset_id", entry.baby_asset_id) or_return
    model: string
    switch entry.model {
    case .Normal: model = "normal"
    case .Cold: model = "cold"
    case .Warm: model = "warm"
    case: unreachable()
    }
    nbt_write_named_string(writer, "model", model) or_return
    return .None
}

@(private="file", require_results)
_serialize_mob_registry_entry :: proc(writer: ^NBTWriter, entry: MobVariantBase) -> WriteError {
    nbt_write_named_string(writer, "asset_id", entry.asset_id) or_return
    return _serialize_spawn_conditions(writer, entry.spawn_conditions)
}

@(private="file", require_results)
_serialize_pig_variant_registry_entry :: proc(writer: ^NBTWriter, entry: PigVariant) -> WriteError {
    _serialize_mob_registry_entry(writer, entry) or_return
    nbt_write_named_string(writer, "baby_asset_id", entry.baby_asset_id) or_return
    nbt_write_named_string(writer, "model", "cold" if entry.model == .Cold else "normal") or_return
    return .None
}

@(private="file", require_results)
_serialize_wolf_variant_registry_entry :: proc(writer: ^NBTWriter, entry: WolfVariant) -> WriteError {
    write_variant(writer, "assets", entry.assets) or_return
    write_variant(writer, "baby_assets", entry.baby_assets) or_return
    return .None
    
    Variant :: intrinsics.type_field_type(WolfVariant, "assets")
    write_variant :: proc(writer: ^NBTWriter, key: string, variant: Variant) -> WriteError {
        nbt_write_named_compound_start(writer, key) or_return
        defer nbt_write_compound_end(writer)
        
        nbt_write_named_string(writer, "angry", variant.angry) or_return
        nbt_write_named_string(writer, "wild", variant.wild) or_return
        nbt_write_named_string(writer, "tame", variant.tame) or_return
        return .None
    }
}

@(private="file", require_results)
_serialize_wolf_sound_variant_registry_entry :: proc(writer: ^NBTWriter, entry: WolfSoundVariant) -> WriteError {
    write_variant(writer, "assets", entry.adult_sounds) or_return
    write_variant(writer, "baby_assets", entry.baby_sounds) or_return
    return .None
    
    Variant :: intrinsics.type_field_type(WolfSoundVariant, "adult_sounds")
    write_variant :: proc(writer: ^NBTWriter, key: string, variant: Variant) -> WriteError {
        nbt_write_named_compound_start(writer, key) or_return
        defer nbt_write_compound_end(writer)
        
        nbt_write_named_string(writer, "ambient_sound", variant.ambient_sound) or_return
        nbt_write_named_string(writer, "death_sound", variant.death_sound) or_return
        nbt_write_named_string(writer, "growl_sound", variant.growl_sound) or_return
        nbt_write_named_string(writer, "hurt_sound", variant.hurt_sound) or_return
        nbt_write_named_string(writer, "pant_sound", variant.pant_sound) or_return
        nbt_write_named_string(writer, "whine_sound", variant.whine_sound) or_return
        return .None
    }
}

@(private="file", require_results)
_serialize_painting_variant_registry_entry :: proc(writer: ^NBTWriter, entry: PaintingVariant) -> WriteError {
    nbt_write_named_string(writer, "asset_id", entry.asset_id) or_return
    nbt_write_named_int(writer, "width", i32(entry.width)) or_return
    nbt_write_named_int(writer, "height", i32(entry.height)) or_return
    unimplemented("TODO: implement TextComponent to nbt conversion")
}

@(private="file", require_results)
_serialize_spawn_conditions :: proc(writer: ^NBTWriter, conditions: []SpawnCondition) -> WriteError {
    nbt_write_named_list_start(writer, "spawn_conditions", .Compound, len(conditions)) or_return
    
    for cond in conditions {
        nbt_write_compound_start(writer)
        defer nbt_write_compound_end(writer)
        
        nbt_write_named_int(writer, "priority", cond.priority) or_return
        // condition may be omitted
        match := cond.condition.? or_continue
        nbt_write_compound_start(writer)
        defer nbt_write_compound_end(writer)
            
        switch match in match {
        case SpawnConditionBiomeMatch:
            nbt_write_named_string(writer, "type", "biome") or_return
            nbt_write_named_list_start(writer, "biomes", .String, len(match.biomes)) or_return
            for biome in match.biomes {
                nbt_write_string(writer, biome) or_return
            }
        case SpawnConditionStructureMatch:
            nbt_write_named_string(writer, "type", "structure") or_return
            nbt_write_named_list_start(writer, "structures", .String, len(match.structures)) or_return
            for structure in match.structures {
                nbt_write_string(writer, structure) or_return
            }
        case SpawnConditionMoonBrightnessMatch:
            nbt_write_named_string(writer, "type", "moon_brightness") or_return
            if match.max == match.max {
                // may be specified as a single double
                nbt_write_named_double(writer, "range", f64(match.min)) or_return
            } else {
                nbt_write_named_compound_start(writer, "range") or_return
                defer nbt_write_compound_end(writer)
                
                nbt_write_named_double(writer, "min", f64(match.min)) or_return
                nbt_write_named_double(writer, "max", f64(match.max)) or_return
            }
        }
    }
    return .None
}

@(private="file", require_results)
_serialize_damage_type_registry_entry :: proc(writer: ^NBTWriter, entry: DamageType) -> WriteError {
    nbt_write_named_string(writer, "message_id", string(entry.message_id)) or_return
    nbt_write_named_float(writer, "exhaustion", entry.exhaustion) or_return
    scaling: string
    switch entry.scaling {
    case .Never: scaling = "never"
    case .Always: scaling = "always"
    case .WhenCausedByLivingNonPlayer: scaling = "when_caused_by_living_non_player"
    case: unreachable()
    }
    nbt_write_named_string(writer, "scaling", scaling) or_return
    if entry.effects != .Hurt { // default
        effects: string
        switch entry.effects {
        case .Thorns: effects = "thorns"
        case .Drowning: effects = "drowning"
        case .Burning: effects = "burning"
        case .Poking: effects = "poking"
        case .Freezing: effects = "freezing"
        case .Hurt: effects = "hurt"
        case: unreachable()
        }
        nbt_write_named_string(writer, "effects", effects) or_return
    }
    if entry.death_message_type != .Default {
        death_message_type: string
        switch entry.death_message_type {
        case .FallVariants: death_message_type = "fall_variants"
        case .IntentionalGameDesign: death_message_type = "intentional_game_design"
        case .Default: death_message_type = "default"
        case: unreachable()
        }
        nbt_write_named_string(writer, "death_message_type", death_message_type) or_return
    }
    return .None
}

@(private="file", require_results)
_serialize_biome_registry_entry :: proc(writer: ^NBTWriter, entry: Biome) -> WriteError {
    unimplemented("TODO: implement biome registry serialization")
}
