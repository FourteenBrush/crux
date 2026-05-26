package crux

import "core:mem"
import "core:net"
import "core:log"
import "core:time"
import "core:slice"

@(private)
SessionData :: struct {
    socket: net.TCP_Socket,
    state: ClientState,
    terminating: bool,
    
    protocol_version: ProtocolVersion,
    // filled in after LoginStartPacket
    game_profile: GameProfile,
    
    clientbound_keepalive: struct {
        // Zero initialized if we haven't sent any.
        sent: time.Tick,
        id: i64,
        awaiting_serverbound: bool,
    },
    
    // TODO: move to global arena list based on epoch, backed by vmem allocator
    packet_scratch_alloc: mem.Allocator,
}

// IMPORTANT NOTE: values must match respective values from HandshakeIntent to allow casting.
// ORDER IS IMPORTANT!!
ClientState :: enum u8 {
    Handshake,
    Status        = auto_cast HandshakeIntent.Status,
    Login         = auto_cast HandshakeIntent.Login,
    Transfer      = auto_cast HandshakeIntent.Transfer,
    Configuration,
    Play,
}
#assert(int(ClientState.Login) <= int(max(HandshakeIntent)))

@(private)
_handle_serverbound_packet :: proc(server: ^Server, packet: ServerBoundPacket, socket: net.TCP_Socket) {
    // get rid of some of the packet spam
    if _, is_client_tick := packet.(ClientTickEndPacket); !is_client_tick {
        log.log(LOG_LEVEL_INBOUND, "Received Packet", packet)
    }
    
    session: ^SessionData
    client_state := get_serverbound_packet_descriptor(packet).expected_client_state
    if client_state > .Handshake {
        // TODO: this logic is not correct in case of stale serverbound packets after we issued some sort of disconnect
        // (which is still buffered in the outbound queue).
        session = &server.sessions[socket] or_else panic("handshake did not create session")
    }
    
    defer if session != nil && session.terminating {
        // only terminate session afterwards (which will remove it from the sessions, causing a use after free if
        // there would have been an accidental extra _enqueue_packet, this procedure will check if we are already terminating)
        // TODO: if we receive a packet afterwards, should be consider it being stale (inside the spsc queue)?
        _terminate_session(server, session^)
    }
    
    switch packet in packet {
    case LegacyServerListPingPacket:
        // session.terminating = true
        // _finalize_client(state, session^)
        // TODO: send TerminateClient message
        return
    case HandshakePacket:
        assert(packet.intent != .Transfer, "TODO: we do not initiate transfers")
        if packet.intent == .Status || packet.intent == .Login {
            // NOTE: session must be created again on .Login
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
            // description = text_component("Some Server", .DarkAqua),
            favicon = _load_favicon(),
            enforces_secure_chat = false,
        }
        enqueue_packet(session, status_response)
    case PingRequestPacket:
        enqueue_packet(session, PongResponsePacket { payload=packet.payload })
        session.terminating = true
    case LoginStartPacket:
        if session.protocol_version != PROTOCOL_VERSION {
            _kick_client(server, session, text_component("Unsupported protocol version", .Red))
            return
        }
        // FIXME: negotiate compression here

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
    case PluginMessagePacket:
        // empty
    case ClientInformationPacket:
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
    case AcknowledgeFinishConfigurationPacket:
        session.state = .Play
        enqueue_packet(session, LoginPacket {
            entity_id = 2,
            is_hardcore = false,
            dimension_names = slice.clone([]Identifier{Identifier("minecraft:overworld")}, session.packet_scratch_alloc),
            max_players = 100,
            view_distance = 8,
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
        // with an incrementally decreasing height field.
        // Will be confirmed with a ConfirmTeleportationPacket
        enqueue_packet(session, SynchronizePlayerPositionPacket {
            y = 65,
        })
    case ClientTickEndPacket:
        // empty
    case SetPlayerRotationPacket:
        // empty
    case SetPlayerPositionPacket:
        // empty
    case SetPlayerPositionRotationPacket:
        // empty
    case ConfirmTeleportationPacket:
        // initial play state position sync got acknowledged, prepare for player spawning
        // TODO: this only has to be sent to other players, vanilla client ignores it though
        add_player_action := PlayerInfoUpdateActionAddPlayer {
            username = session.game_profile.username,
            properties = {},
        }
        gamemode_change := PlayerInfoUpdateActionUpdateGameMode {
            new_mode = .Spectator,
        }
        add_to_tablist := PlayerInfoUpdateActionUpdateListed { listed=true }
        enqueue_packet(session, PlayerInfoUpdatePacket {
            players = slice.clone([]PlayerInfoUpdateEntry{
                { 
                    uuid = session.game_profile.uuid,
                    actions = slice.clone([]PlayerInfoUpdateAction{
                        add_player_action,
                        gamemode_change,
                        add_to_tablist,
                    }, session.packet_scratch_alloc),
                },
            }, session.packet_scratch_alloc),
        })
        enqueue_packet(session, PlayerAbilitiesPacket {
            flags = {.AllowFlying, .Flying},
            flying_speed = 0.05,
            fov_modifier = 0.1,
        })
        enqueue_packet(session, StartWaitingForChunks {})
    case PlayerLoadedPacket:
        // empty
    case KeepAlivePlayPacket:
        last_keepalive := &session.clientbound_keepalive
        if !last_keepalive.awaiting_serverbound {
            _kick_client(server, session, text_component("Unexpected keepalive", .Red))
            return
        }
        if packet.id != Long(last_keepalive.id) {
            _kick_client(server, session, text_component("Keepalive id mismatch", .Red))
            return
        }
        last_keepalive.awaiting_serverbound = false
    case SwingArmPacket:
        // empty
    case PlayerInputPacket:
        // empty
    case PlayerFlightChangePacket:
        // empty
    case StoreCookiePlayPacket:
        // empty
    }
}

@(private="file")
_send_registry_data :: proc(session: ^SessionData) {
    assert(session.state == .Configuration)
    
    enqueue_packet(session, DimensionTypeRegistry {
        entries = slice.clone([]RegistryEntry(DimensionType){
            0 = { id = Identifier("minecraft:overworld"), data = nil },
        }, session.packet_scratch_alloc),
    })
    enqueue_packet(session, CatVariantRegistry {
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
    })
    enqueue_packet(session, ChickenVariantRegistry {
        entries = slice.clone([]RegistryEntry(ChickenVariant){
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        }, session.packet_scratch_alloc),
    })
    enqueue_packet(session, CowVariantRegistry {
        entries = slice.clone([]RegistryEntry(CowVariant){
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        }, session.packet_scratch_alloc),
    })
    enqueue_packet(session, FrogVariantRegistry {
        entries = slice.clone([]RegistryEntry(FrogVariant){
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        }, session.packet_scratch_alloc),
    })
    enqueue_packet(session, PigVariantRegistry {
        entries = slice.clone([]RegistryEntry(PigVariant){
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        }, session.packet_scratch_alloc),
    })
    enqueue_packet(session, WolfVariantRegistry {
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
    })
    enqueue_packet(session, WolfSoundVariantRegistry {
        entries = slice.clone([]RegistryEntry(WolfSoundVariant){
            { id = Identifier("minecraft:angry"), data = nil },
            { id = Identifier("minecraft:big"), data = nil },
            { id = Identifier("minecraft:classic"), data = nil },
            { id = Identifier("minecraft:cute"), data = nil },
            { id = Identifier("minecraft:grumpy"), data = nil },
            { id = Identifier("minecraft:puglin"), data = nil },
            { id = Identifier("minecraft:sad"), data = nil },
        }, session.packet_scratch_alloc),
    })
    enqueue_packet(session, PaintingVariantRegistry {
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
    })
    enqueue_packet(session, DamageTypeRegistry {
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
    })
    // a minecraft:plains biome is required as default biome before a login packet will be accepted
    enqueue_packet(session, BiomeRegistry {
        entries = slice.clone([]RegistryEntry(Biome){
            { id = Identifier("minecraft:plains"), data = nil },
        }, session.packet_scratch_alloc),
    })
}