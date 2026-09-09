#+vet explicit-allocators
package crux

import "core:time"
import "core:fmt"
import "core:net"
import "core:log"
import "core:math"
import "core:slice"

import "src:items"

Pos :: [3]f64

pos_to_chunk :: proc "contextless" (pos: Pos) -> ChunkPos {
    return {
        cast(i32)math.floor(pos.x / 16),
        cast(i32)math.floor(pos.z / 16),
    }
}

@(private)
_handle_serverbound_packet :: proc(server: ^Server, packet: ServerBoundPacket, socket: net.TCP_Socket, client_state: ClientState) {
    #partial switch packet in packet {
    case ClientTickEndPacket,
        KeepAlivePlayPacket,
        SetPlayerRotationPacket,
        SetPlayerPositionPacket,
        SetPlayerPositionRotationPacket,
        SetPlayerMovementPacket,
        PlayerInputPacket,
        PlayerCommandPacket,
        SwingArmPacket:
        // do not log, spams console
    case:
        log.log(LOG_LEVEL_INBOUND, "Received Packet", packet)
    }
    
    session: ^SessionData = nil
    if client_state > .Handshake {
        // TODO: this logic is not correct in case of stale serverbound packets after we issued some sort of disconnect
        // (which is still buffered in the outbound queue).
        session = &server.sessions[socket] or_else panic("handshake did not create session")
    }
    
    defer if session != nil && session.terminating {
        // only terminate session afterwards (which will remove it from the sessions, causing a use after free if
        // there would have been an accidental extra _enqueue_packet, this procedure will check if we are already terminating)
        // TODO: if we receive a packet afterwards, should we consider it being stale (inside the spsc queue)?
        _terminate_session(server, session^, .Local)
    }
    
    switch packet in packet {
    case LegacyServerListPingPacket:
        if session != nil {
            session.terminating = true
        } else {
            spsc_enqueue(server.outbound_queue, TerminateClientRequest { client=socket })
        }
    case HandshakePacket:
        switch packet.intent {
        case .Transfer:
            // TODO: kick instead of panic
            assert(packet.intent != .Transfer, "TODO: we do not initiate transfers")
            // _kick_client(server, session)
        case .Status, .Login:
            // NOTE: session must be created again on .Login if this was a .Status intent
            if packet.intent == .Login do assert(session == nil, "did not terminate session after handshake and status request")
            // client may have sent unsupported protocol version if the packet intent was .Login, but there is no way
            // to kick them with a custom message here (no disconnect packet for Handshake state exist),
            // so we wait till the first Login state packet (LoginStart) and kick them there.
            
            // game profile filled in on LoginStart
            created_session := _create_session(socket, ClientState(packet.intent), packet.protocol_version)
            session = map_insert(&server.sessions, socket, created_session)
        }
    case StatusRequestPacket:
        online_players := 0
        for _, conn in server.sessions do if conn.state == .Play {
            online_players += 1
        }
        
        status_response := StatusResponsePacket {
            version = {
                name = GAME_VERSION_STR,
                protocol = PROTOCOL_VERSION,
            },
            players = {
                max = 100,
                online = uint(online_players),
            },
            description = text_component("Some Server", .DarkAqua),
            favicon = _load_favicon(),
            enforces_secure_chat = false,
        }
        enqueue_packet(session, status_response)
    case PingRequestPacket:
        enqueue_packet(session, PongResponsePacket { payload=packet.payload })
        session.terminating = true
    case LoginStartPacket:
        if session.protocol_version != PROTOCOL_VERSION {
            error_msg := fmt.aprintf(
                "Incompatible protocol version (Client: %d Server: %d)",
                session.protocol_version, PROTOCOL_VERSION,
                // TODO: bad read on io thread for some reason when using scratch alloc, not when using mutex alloc
                allocator=session.packet_scratch_alloc,
            )
            _kick_client(server, session, text_component(error_msg, .Red))
            return
        }
        player_set_compression(session, COMPRESSION_THRESHOLD)
        
        // TODO: fetch skin here and cache
        session.game_profile = GameProfile {
            uuid = packet.uuid,
            username = packet.username,
            name = "textures",
            value = "somestringhere",
            signature = nil,
        }
        enqueue_packet(session, LoginSuccessPacket { game_profile=session.game_profile })
    case LoginAcknowledgedPacket:
        session.state = .Configuration
        player_send_keepalive(session, 012375873, time.tick_now())
    case PluginMessagePacket:
        // empty
    case ClientInformationPacket:
        if client_state != .Configuration do break
        
        // from here on, send server configuration until we reach a serverbound finish config ack
        enqueue_packet(session, PluginMessagePacket {
            channel = "minecraft:brand",
            // TODO: hand crafted for now, will we store the payload as a NetworkBuffer in the future?
            // payload for minecraft:brand is a length prefixed string
            payload = slice.clone([]u8{ len("crux"), 'c', 'r', 'u', 'x' }, session.packet_scratch_alloc),
        })
        enqueue_packet(session, KnownPacksPacket {
            known_packs = slice.clone([]KnownPack{
                { namespace = "minecraft", id = "core", version = "1.21.10" },
            }, session.packet_scratch_alloc),
        })
    case KnownPacksPacket:
        ensure_has_core: for pack, i in packet.known_packs {
            if pack.namespace != "minecraft" && pack.id != "core" {
                if i == len(packet.known_packs) - 1 {
                    kick_reason := text_component("No mutual minecraft:core known packs", TextColor(0xffaacc), {.Bold})
                    _kick_client(server, session, kick_reason)
                    break ensure_has_core
                }
            }
        }
        
        _send_registry_data(session)
        
        enqueue_packet(session, FinishConfigurationPacket {})
    case KeepAliveConfigurationPacket:
        _player_handle_keepalive(server, session, packet.id)
    case AcknowledgeFinishConfigurationPacket:
        session.state = .Play
        enqueue_packet(session, LoginPacket {
            entity_id = 2,
            is_hardcore = false,
            dimension_names = slice.clone([]Identifier{Identifier("minecraft:overworld")}, session.packet_scratch_alloc),
            max_players = 100,
            view_distance = VIEW_DISTANCE,
            simulation_distance = 6,
            reduced_debug_info = false,
            enable_respawn_screen = true,
            do_limited_crafting = true,
            dimension_type = 0,
            dimension_name = Identifier("minecraft:overworld"),
            hashed_seed = 0x6816257285065639, // random
            gamemode = .Survival,
            prev_gamemode = nil,
            is_debug = false,
            is_flat = false,
            death_location = nil,
            portal_cooldown = 40,
            sea_level = 65,
            enforces_secure_chat = false,
        })
        
        // if we do not send a position sync, the client keeps sending set player position packets
        // with an decreasing height field.
        // Will be confirmed with a ConfirmTeleportationPacket
        player_teleport(session, {1, 65, 1})
    case ClientTickEndPacket:
        // empty
    case SetPlayerPositionPacket:
        // ignore position changes while awaiting a teleport confirmation (vanilla behavior)
        if session.pending_teleport != nil do return
        
        if player_crosses_chunk_borders(session, packet.pos) {
            player_chunk_pos := pos_to_chunk(session.pos)
            entering_chunk_pos := pos_to_chunk(packet.pos)
            enqueue_packet(session, SetCenterChunkPacket {
                chunk_pos = entering_chunk_pos,
            })

            if entering_chunk_pos.y != player_chunk_pos.y {
                // check if position ahead of the entered chunk has to be sent
                if abs(entering_chunk_pos.y) + 1 >= CENTER_OFFSET {
                    // {-1, -1} when moving on axis in negative direction, {1, 1} otherwise
                    direction: ChunkPos = math.sign(entering_chunk_pos.y - player_chunk_pos.y)
                    log.warn("sending chunk ahead of z axis")
                    _player_send_chunk(session, entering_chunk_pos + {0, 1} * direction, .Stone)
                    
                    _player_send_chunk(session, entering_chunk_pos + {-1, 1} * direction, .Air)
                    _player_send_chunk(session, entering_chunk_pos + {-1, 2} * direction, .Air)
                    _player_send_chunk(session, entering_chunk_pos + {0, 2} * direction, .Air)
                    _player_send_chunk(session, entering_chunk_pos + {1, 2} * direction, .Air)
                    _player_send_chunk(session, entering_chunk_pos + {1, 1} * direction, .Air)
                }
            }

            // if chunk outside of loading area, send as air chunk
            // loading_offset := i32(2 * VIEW_DISTANCE + 7) / 2
            // loading_offset := i32(4)
            // if abs(new_chunk_pos.x) > loading_offset || abs(new_chunk_pos.y) > loading_offset {
            //     log.warn("sending chunk")
            //     _player_send_chunk(session, new_chunk_pos, .Stone)
            // }
        }
        session.pos = packet.pos
    case SetPlayerRotationPacket:
        // empty
    case SetPlayerPositionRotationPacket:
        // empty
    case SetPlayerMovementPacket:
        // empty
    case ConfirmTeleportationPacket:
        pending_teleport, has_pending := session.pending_teleport.?
        if !has_pending {
            _kick_client(server, session, text_component("Unexpected teleport confirmation", .Red))
            return
        }
        if packet.teleport_id != pending_teleport.id {
            _kick_client(server, session, text_component("Teleport confirmation id mismatch", .Red))
            return
        }
        
        session.pos = pending_teleport.pos
        session.pending_teleport = nil
        
        if !session.spawned {
            // initial play state position sync got acknowledged, prepare for player spawning
            
            // send add player packet to other players
            for _, &player in server.sessions {
                // looks like we need to include the joining player as well, or we wont be shown on the tab list
                if player.state != .Play do continue
                
                add_player_action := PlayerInfoUpdateActionAddPlayer {
                    username = session.game_profile.username,
                    properties = {},
                }
                add_player_packet_entry := PlayerInfoUpdateEntry {
                    uuid = session.game_profile.uuid,
                    actions = slice.clone([]PlayerInfoUpdateAction { add_player_action }, session.packet_scratch_alloc),
                }
                enqueue_packet(&player, PlayerInfoUpdatePacket {
                    players = slice.clone([]PlayerInfoUpdateEntry { add_player_packet_entry }, session.packet_scratch_alloc),
                })
            }
            _player_initiate_spawning(session)
            session.spawned = true
        }
    case PlayerLoadedPacket:
        // empty
    case KeepAlivePlayPacket:
        _player_handle_keepalive(server, session, packet.id)
    case SwingArmPacket:
        // empty
    case PlayerInputPacket:
        // empty
    case PlayerFlightChangePacket:
        // empty
    case StoreCookiePlayPacket:
        // empty
    case SetHeldItemPacket:
        if packet.slot < PLAYER_INV_MIN_SLOT || packet.slot > PLAYER_INV_MAX_SLOT {
            _kick_client(server, session, text_component(fmt.tprint("Invalid inventory slot", packet.slot), COLOR_RED))
            return
        }
        session.inventory.held_item_slot = packet.slot
    case CloseContainerPacket:
        // empty
    case PlayerCommandPacket:
        // empty
    case PlayerActionPacket:
        #partial switch packet.status {
        case .StartDigging:
            // TODO: if this is != nil, can we assume the client did not sent a CancelledDigging?
            session.current_breaking_sequence = i32(packet.sequence)
        case .FinishedDigging:
            if session.current_breaking_sequence == nil {
                _kick_client(server, session, text_component("Sent a finished digging packet without corresponding start digging", COLOR_RED))
                return
            }
            session.current_breaking_sequence = nil
            
            player_inventory_add_item(session, items.ItemStack { count=1, type=&items.DIRT })
        }
    case ChatCommandPacket:
        if packet.command == "reset" {
            // reset level chunks to initial layout
            _player_send_initial_chunks(session, VIEW_DISTANCE)
        }
    case ClickContainerPacket:
        if (packet.slot < PLAYER_INV_MIN_SLOT || packet.slot > PLAYER_INV_MAX_SLOT) && packet.slot != -999 {
            kick_msg := fmt.aprintf("Invalid inventory slot", packet.slot, allocator=session.packet_scratch_alloc)
            _kick_client(server, session, text_component(kick_msg, COLOR_RED))
            return
        }
        _player_dispatch_container_click(session, mode=i32(packet.mode), button=i32(packet.button), slot=packet.slot)
    case UseItemOnPacket:
        // empty
    case UseItemPacket:
        // empty
    }
}

@(private="file")
_player_handle_keepalive :: proc(server: ^Server, session: ^SessionData, id: Long) {
    id := i64(id)
    
    last_keepalive := &session.clientbound_keepalive
    if !last_keepalive.awaiting_serverbound {
        _kick_client(server, session, text_component("Unexpected keepalive", .Red))
        return
    }
    if id != last_keepalive.id {
        _kick_client(server, session, text_component("Keepalive id mismatch", .Red))
        return
    }
    last_keepalive.awaiting_serverbound = false
}

@(private="file")
_send_registry_data :: proc(session: ^SessionData) {
    assert(session.state == .Configuration)
    
    enqueue_packet(session, RegistryDataPacket(DimensionTypeRegistry {
        entries = slice.clone([]RegistryEntry(DimensionType){
            0 = { id = Identifier("minecraft:overworld"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(CatVariantRegistry {
        entries = slice.clone([]RegistryEntry(CatVariant){
            { id = Identifier("minecraft:tabby"), data = nil },
            { id = Identifier("minecraft:black"), data = nil },
            { id = Identifier("minecraft:red"), data = nil },
            { id = Identifier("minecraft:siamese"), data = nil },
            { id = Identifier("minecraft:british_shorthair"), data = nil },
            { id = Identifier("minecraft:calico"), data = nil },
            { id = Identifier("minecraft:persian"), data = nil },
            { id = Identifier("minecraft:ragdoll"), data = nil },
            { id = Identifier("minecraft:white"), data = nil },
            { id = Identifier("minecraft:jellie"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(ChickenVariantRegistry {
        entries = slice.clone([]RegistryEntry(ChickenVariant){
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(CowVariantRegistry {
        entries = slice.clone([]RegistryEntry(CowVariant){
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(FrogVariantRegistry {
        entries = slice.clone([]RegistryEntry(FrogVariant){
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(PigVariantRegistry {
        entries = slice.clone([]RegistryEntry(PigVariant){
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(WolfVariantRegistry {
        entries = slice.clone([]RegistryEntry(WolfVariant){
            { id = Identifier("minecraft:ashen"), data = nil },
            { id = Identifier("minecraft:black"), data = nil },
            { id = Identifier("minecraft:chestnut"), data = nil },
            { id = Identifier("minecraft:pale"), data = nil },
            { id = Identifier("minecraft:rusty"), data = nil },
            { id = Identifier("minecraft:snowy"), data = nil },
            { id = Identifier("minecraft:spotted"), data = nil },
            { id = Identifier("minecraft:striped"), data = nil },
            { id = Identifier("minecraft:woods"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(WolfSoundVariantRegistry {
        entries = slice.clone([]RegistryEntry(WolfSoundVariant){
            { id = Identifier("minecraft:angry"), data = nil },
            { id = Identifier("minecraft:big"), data = nil },
            { id = Identifier("minecraft:classic"), data = nil },
            { id = Identifier("minecraft:cute"), data = nil },
            { id = Identifier("minecraft:grumpy"), data = nil },
            { id = Identifier("minecraft:puglin"), data = nil },
            { id = Identifier("minecraft:sad"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(PaintingVariantRegistry {
        entries = slice.clone([]RegistryEntry(PaintingVariant){
            { id = Identifier("minecraft:alban"), data = nil },
            { id = Identifier("minecraft:aztec"), data = nil },
            { id = Identifier("minecraft:aztec2"), data = nil },
            { id = Identifier("minecraft:backyard"), data = nil },
            { id = Identifier("minecraft:baroque"), data = nil },
            { id = Identifier("minecraft:bomb"), data = nil },
            { id = Identifier("minecraft:bouquet"), data = nil },
            { id = Identifier("minecraft:burning_skull"), data = nil },
            { id = Identifier("minecraft:bust"), data = nil },
            { id = Identifier("minecraft:cavebird"), data = nil },
            { id = Identifier("minecraft:changing"), data = nil },
            { id = Identifier("minecraft:cotan"), data = nil },
            { id = Identifier("minecraft:courbet"), data = nil },
            { id = Identifier("minecraft:creebet"), data = nil },
            { id = Identifier("minecraft:dennis"), data = nil },
            { id = Identifier("minecraft:donkey_kong"), data = nil },
            { id = Identifier("minecraft:earth"), data = nil },
            { id = Identifier("minecraft:fern"), data = nil },
            { id = Identifier("minecraft:fighters"), data = nil },
            { id = Identifier("minecraft:finding"), data = nil },
            { id = Identifier("minecraft:fire"), data = nil },
            { id = Identifier("minecraft:graham"), data = nil },
            { id = Identifier("minecraft:humble"), data = nil },
            { id = Identifier("minecraft:kebab"), data = nil },
            { id = Identifier("minecraft:lowmist"), data = nil },
            { id = Identifier("minecraft:match"), data = nil },
            { id = Identifier("minecraft:meditative"), data = nil },
            { id = Identifier("minecraft:orb"), data = nil },
            { id = Identifier("minecraft:owlemons"), data = nil },
            { id = Identifier("minecraft:passage"), data = nil },
            { id = Identifier("minecraft:pigscene"), data = nil },
            { id = Identifier("minecraft:plant"), data = nil },
            { id = Identifier("minecraft:pointer"), data = nil },
            { id = Identifier("minecraft:pond"), data = nil },
            { id = Identifier("minecraft:pool"), data = nil },
            { id = Identifier("minecraft:prairie_ride"), data = nil },
            { id = Identifier("minecraft:sea"), data = nil },
            { id = Identifier("minecraft:skeleton"), data = nil },
            { id = Identifier("minecraft:skull_and_roses"), data = nil },
            { id = Identifier("minecraft:stage"), data = nil },
            { id = Identifier("minecraft:sunflowers"), data = nil },
            { id = Identifier("minecraft:sunset"), data = nil },
            { id = Identifier("minecraft:tides"), data = nil },
            { id = Identifier("minecraft:unpacked"), data = nil },
            { id = Identifier("minecraft:void"), data = nil },
            { id = Identifier("minecraft:wanderer"), data = nil },
            { id = Identifier("minecraft:wasteland"), data = nil },
            { id = Identifier("minecraft:water"), data = nil },
            { id = Identifier("minecraft:wind"), data = nil },
            { id = Identifier("minecraft:wither"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    enqueue_packet(session, RegistryDataPacket(DamageTypeRegistry {
        entries = slice.clone([]RegistryEntry(DamageType){
            { id = Identifier("minecraft:arrow"), data = nil },
            { id = Identifier("minecraft:bad_respawn_point"), data = nil },
            { id = Identifier("minecraft:cactus"), data = nil },
            { id = Identifier("minecraft:campfire"), data = nil },
            { id = Identifier("minecraft:cramming"), data = nil },
            { id = Identifier("minecraft:dragon_breath"), data = nil },
            { id = Identifier("minecraft:drown"), data = nil },
            { id = Identifier("minecraft:dry_out"), data = nil },
            { id = Identifier("minecraft:ender_pearl"), data = nil },
            { id = Identifier("minecraft:explosion"), data = nil },
            { id = Identifier("minecraft:fall"), data = nil },
            { id = Identifier("minecraft:falling_anvil"), data = nil },
            { id = Identifier("minecraft:falling_block"), data = nil },
            { id = Identifier("minecraft:falling_stalactite"), data = nil },
            { id = Identifier("minecraft:fireball"), data = nil },
            { id = Identifier("minecraft:fireworks"), data = nil },
            { id = Identifier("minecraft:fly_into_wall"), data = nil },
            { id = Identifier("minecraft:freeze"), data = nil },
            { id = Identifier("minecraft:generic"), data = nil },
            { id = Identifier("minecraft:generic_kill"), data = nil },
            { id = Identifier("minecraft:hot_floor"), data = nil },
            { id = Identifier("minecraft:in_fire"), data = nil },
            { id = Identifier("minecraft:in_wall"), data = nil },
            { id = Identifier("minecraft:indirect_magic"), data = nil },
            { id = Identifier("minecraft:lava"), data = nil },
            { id = Identifier("minecraft:lightning_bolt"), data = nil },
            { id = Identifier("minecraft:mace_smash"), data = nil },
            { id = Identifier("minecraft:magic"), data = nil },
            { id = Identifier("minecraft:mob_attack"), data = nil },
            { id = Identifier("minecraft:mob_attack_no_aggro"), data = nil },
            { id = Identifier("minecraft:mob_projectile"), data = nil },
            { id = Identifier("minecraft:on_fire"), data = nil },
            { id = Identifier("minecraft:out_of_world"), data = nil },
            { id = Identifier("minecraft:outside_border"), data = nil },
            { id = Identifier("minecraft:player_attack"), data = nil },
            { id = Identifier("minecraft:player_explosion"), data = nil },
            { id = Identifier("minecraft:sonic_boom"), data = nil },
            { id = Identifier("minecraft:spit"), data = nil },
            { id = Identifier("minecraft:stalagmite"), data = nil },
            { id = Identifier("minecraft:starve"), data = nil },
            { id = Identifier("minecraft:sting"), data = nil },
            { id = Identifier("minecraft:sweet_berry_bush"), data = nil },
            { id = Identifier("minecraft:thorns"), data = nil },
            { id = Identifier("minecraft:thrown"), data = nil },
            { id = Identifier("minecraft:trident"), data = nil },
            { id = Identifier("minecraft:unattributed_fireball"), data = nil },
            { id = Identifier("minecraft:wind_charge"), data = nil },
            { id = Identifier("minecraft:wither"), data = nil },
            { id = Identifier("minecraft:wither_skull"), data = nil },
        }, session.packet_scratch_alloc),
    }))
    // a minecraft:plains biome is required as default biome before a login packet will be accepted
    enqueue_packet(session, RegistryDataPacket(BiomeRegistry {
        entries = slice.clone([]RegistryEntry(Biome){
            BiomeId.Plains = { id = Identifier("minecraft:plains"), data = nil },
        }, session.packet_scratch_alloc),
    }))
}
