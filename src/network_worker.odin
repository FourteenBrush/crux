// Worker thread responsable for network related things like performing
// IO on client sockets, (de)serialization and transmission of packets.
package crux

import "core:os"
import "core:time"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "base:runtime"
import "core:sync/chan"

import "src:reactor"

import "lib:tracy"

@(private="file")
WORKER_TARGET_MSPT :: 5

// The capacity of the allocator that allocates per client packet specific data, if this allocator
// fills up, old data will be overwritten.
@(private="file")
PACKET_SCRATCH_BUFFER_SIZE :: 256 * 1024

NetworkWorkerSharedData :: struct {
    io_ctx: ^reactor.IOContext,
    // Non-blocking server socket.
    server_sock: net.TCP_Socket,
    // An allocator to be used by this thread, must be owned by this thread or be thread safe.
    threadsafe_alloc: mem.Allocator,
    // Ptr to atomic bool, indicating whether to continue running, modified upstream.
    execution_permit: ^bool,
    // Packet channel back to main thread.
    packet_bridge: chan.Chan(Packet, .Send),
}

// All members are explicitly owned by this thread, unless specified otherwise.
@(private="file")
NetworkWorkerState :: struct {
    using shared: NetworkWorkerSharedData,
    connections: map[net.TCP_Socket]ClientConnection,
    
    // World data essentially, TODO: move this out to some world abstraction once this is established
    sessions: map[net.TCP_Socket]SessionData,
}

// IO client context.
ClientConnection :: struct {
    // Non blocking socket
    socket: net.TCP_Socket,
    state: ClientState,
    // Whether a packet has been sent with an `is_terminal` flag set to true or an explicit termination
    // request was issued, this indicates that this connection will be closed shortly
    // and any consecutive `enqueue_packet` calls will silently ignore that packet.
    terminating: bool,
    // Number of outstanding write operations, which has not yet received a completion.
    // This acts as a refcount to the allocator data being stored here, to ensure all writes are properly deallocated.
    // While it is not an issue to just clear the whole allocator at once (effectively getting rid of the writes
    // needing to be deallocated problem), it remains important that we do not close this connection till all
    // writes are flushed (as there may be a terminal packet at the end of the tx buf, which definitely needs to be transferred).
    // When this number reaches zero, and `terminating` is true, this connection will be fully closed and cleaned up.
    outstanding_writes: int,
    
    // Allocator to deal with all packet related allocations, overwriting itself
    // if there is too much backpressure.
    packet_scratch_alloc: mem.Allocator,

    rx_buf: NetworkBuffer,
    // FIXME: may in fact be a linear buffer as it is always sent at once
    tx_buf: NetworkBuffer,
    
    clientbound_keepalive: struct {
        // Zero initialized if we haven't sent any.
        sent: time.Tick,
        id: i64,
        awaiting_serverbound: bool,
    },
}

// Whether a ClientConnection may be finalized after receiving a completion.
@(private="file")
_should_finalize_disconnect :: proc(conn: ClientConnection) -> bool {
    return conn.terminating && conn.outstanding_writes == 0
}

@(private="file")
SessionData :: struct {
    protocol_version: ProtocolVersion,
    game_profile: GameProfile,
}

// TODO: logger is not threadsafe
@(private)
_network_worker_thread_proc :: proc(shared: ^NetworkWorkerSharedData) {
    tracy.SetThreadName("crux-NetWorker")
    state := NetworkWorkerState {
        shared = shared^,
        connections = make(map[net.TCP_Socket]ClientConnection, 16, os.heap_allocator()),
        sessions = make(map[net.TCP_Socket]SessionData, 16, os.heap_allocator()),
    }

    defer cleanup: {
        log.debug("shutting down worker")
        _network_worker_atexit(&state)
        // destroy temp alloc when this refers to the default one (thread_local)
        if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
            runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        }
    }

    for sync.atomic_load(state.execution_permit) {
        start := time.tick_now()
        defer {
            tick_duration := time.tick_since(start)
            target_tick_time := WORKER_TARGET_MSPT * time.Millisecond
            if tick_duration < target_tick_time {
                tracy.ZoneNC("Worker Sleep", color=0x9c4433)
                // TODO: dynamically scale, if theres nothing to do, just sleep a bit longer
                time.sleep(target_tick_time - tick_duration)
            }
            free_all(context.temp_allocator)
            tracy.FrameMark("Worker")
        }

        _network_worker_run_tick(&state)
        
        // send keepalive packets, required every 1-15 secs, disconnected after 20 secs
        KEEPALIVE_INTRVAL :: 13 * time.Second
        KEEPALIVE_TIMEOUT :: 20 * time.Second
        // FIXME: would ideally base this of world ticks instead of monotonic clock syscalls
        now := time.tick_now()
        for _, &client_conn in state.connections {
            if client_conn.state != .Play || client_conn.terminating do continue
            
            last_keepalive := &client_conn.clientbound_keepalive
            if last_keepalive.awaiting_serverbound {
                elapsed := time.tick_diff(last_keepalive.sent, now)
                if elapsed > KEEPALIVE_TIMEOUT {
                    _kick_client(&state, &client_conn, text_component("Timed out", .Red))
                    continue
                }
            }
            
            elapsed := time.tick_diff(last_keepalive.sent, now)
            if elapsed > KEEPALIVE_INTRVAL {
                id := i64(elapsed)
                enqueue_packet(state.io_ctx, &client_conn, KeepAlivePlayPacket { id=Long(id) })
                last_keepalive.sent = now
                last_keepalive.id = id
                last_keepalive.awaiting_serverbound = true
            }
        }
    }
}

@(private="file")
_network_worker_run_tick :: proc(state: ^NetworkWorkerState) {
    REACTOR_TIMEOUT_MS :: 1
    #assert(REACTOR_TIMEOUT_MS < WORKER_TARGET_MSPT)

    completions: [512]reactor.Completion
    // NOTE: do not indefinitely block or this thread can't be joined
    // TODO: scale down timer resolution when no clients are connected
    nready, await_ok := reactor.await_io_completions(state.io_ctx, completions[:], timeout_ms=REACTOR_TIMEOUT_MS)
    assert(await_ok, "failed to await io events") // TODO: proper error handling

    for comp in completions[:nready] {
        tracy.ZoneN("ProcessCompletion")
        
        client_conn := &state.connections[comp.socket]
        comp_holds_conn_alive := comp.operation == .Write || (comp.operation == .Error && comp.buf != nil)
        assert(
            client_conn != nil || !comp_holds_conn_alive,
            "completion with outstanding write ownership arrived after ClientConnection destruction",
        )
        if comp_holds_conn_alive {
            client_conn.outstanding_writes -= 1
        }

        switch comp.operation {
        case .Error:
            log.debug("client socket error")
            // if caused by a write operation, free our allocated submission which was returned back to us
            if comp.buf != nil {
                assert(client_conn != nil)
                delete(comp.buf, client_conn.packet_scratch_alloc)
            }
            if _should_finalize_disconnect(client_conn^) {
                _finalize_client(state, client_conn^)
            }
        case .PeerHangup:
            log.debug("client socket hangup")
            // client_conn is nil when we disconnected from the peer first, thus only serving as a confirmation
            if client_conn != nil {
                client_conn.terminating = true
                if _should_finalize_disconnect(client_conn^) {
                    _finalize_client(state, client_conn^)
                }
            }
        case .Read:
            defer reactor.release_recv_buf(state.io_ctx, comp)
            if client_conn == nil || client_conn.terminating {
                continue
            }
            buf_write_bytes(&client_conn.rx_buf, comp.buf) // copies
            _drain_serverbound_packets(state, client_conn)
        case .Write:
            // must be freed using the same allocator the reactor write call was made with
            delete(comp.buf, client_conn.packet_scratch_alloc)
            if _should_finalize_disconnect(client_conn^) {
                log.debug("disconnecting client as requested")
                _finalize_client(state, client_conn^)
            }
        case .NewConnection:
            packet_scratch := new(mem.Scratch, os.heap_allocator())
            mem.scratch_init(packet_scratch, PACKET_SCRATCH_BUFFER_SIZE, backup_allocator=os.heap_allocator())
            // NOTE: disallow out of band allocations larger than allocator cap, as they would be leaked either way
            packet_scratch.backup_allocator = mem.panic_allocator()
            packet_scratch.leaked_allocations.allocator = mem.panic_allocator()
            
            state.connections[comp.socket] = ClientConnection {
                socket = comp.socket,
                state  = .Handshake,
                
                packet_scratch_alloc = mem.scratch_allocator(packet_scratch),
                rx_buf = create_network_buf(10240, allocator=os.heap_allocator()),
                tx_buf = create_network_buf(10240, allocator=os.heap_allocator()),
            }

            log.debugf("client connected (fd %d)", comp.socket)
        }
    }
}

@(private="file")
_network_worker_atexit :: proc(state: ^NetworkWorkerState) {
    // TODO: linger to ensure all client bufs are flushed, maybe even send "Server Closed" disconnect packet
    for _, client_conn in state.connections {
        _finalize_client(state, client_conn)
    }
    delete(state.connections)
}

@(private="file")
_drain_serverbound_packets :: proc(state: ^NetworkWorkerState, client_conn: ^ClientConnection) {
    tracy.Zone()

    loop: for {
        packet, err := read_serverbound(&client_conn.rx_buf, client_conn.state, allocator=client_conn.packet_scratch_alloc)
        switch err {
        case .ShortRead: break loop
        case .InvalidData:
            log.debug("client sent malformed packet, kicking; buf=")
            buf_dump(client_conn.rx_buf)
            _kick_client(state, client_conn, text_component_single("Sent an unimplemented packet", TextColor(0xD92625)))
            break loop
        case .None:
            packet_desc := get_serverbound_packet_descriptor(packet)
            if packet_desc.expected_client_state != client_conn.state {
                log.debugf("client sent packet in wrong client state (%v != %v): %v", client_conn.state, packet_desc.expected_client_state, packet)
                _finalize_client(state, client_conn^)
                break loop
            }

            _handle_clientbound_packet(state, packet, client_conn)
            success := chan.try_send(state.packet_bridge, packet)
            if !success {
                // TODO: do we even need a channel, what about a futex/atomic mutex and a darray?
                log.error("tried sending packet to main thread but channel buf is full")
            }
            if client_conn.terminating do break loop
        }
    }
}

@(private="file")
_handle_clientbound_packet :: proc(state: ^NetworkWorkerState, packet: ServerBoundPacket, client_conn: ^ClientConnection) {
    // get rid of some of the packet spam
    if _, is_client_tick := packet.(ClientTickEndPacket); !is_client_tick {
        log.log(LOG_LEVEL_INBOUND, "Received Packet", packet)
    }

    switch packet in packet {
    case LegacyServerListPingPacket:
        _finalize_client(state, client_conn^)
        return
    case HandshakePacket:
        if packet.intent == .Login {
            // client may have an unsupported protocol version, but there is no way to kick them with a custom message here
            // (no disconnect packet for Handshake state exist), so we wait till the first Login state packet (LoginStart)
            // and kick them there.
            map_insert(&state.sessions, client_conn.socket, SessionData { 
                protocol_version = packet.protocol_version,
                game_profile = {}, // filled in on LoginStart
            })
        }
        client_conn.state = ClientState(packet.intent) // safe to cast
    case StatusRequestPacket:
        online_players := 0
        for _, conn in state.connections do if conn.state == .Play {
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
            favicon = "data:image/png;base64,<data>",
            enforces_secure_chat = false,
        }
        enqueue_packet(state.io_ctx, client_conn, status_response)
    case PingRequestPacket:
        enqueue_packet(state.io_ctx, client_conn, PongResponsePacket { payload=packet.payload })
        client_conn.terminating = true
    case LoginStartPacket:
        session_data := _get_session(state, client_conn)
        if session_data.protocol_version != PROTOCOL_VERSION {
            _kick_client(state, client_conn, text_component("Unsupported protocol version", .Red))
            return
        }
        // FIXME: negotiate compression here

        // TODO: fetch skin here and cache
        session_data.game_profile = GameProfile {
            uuid = packet.uuid,
            username = packet.username,
            name = "textures",
            value = "somestringhere",
            signature = nil,
        }
        enqueue_packet(state.io_ctx, client_conn, LoginSuccessPacket { game_profile=session_data.game_profile })
    case LoginAcknowledgedPacket:
        client_conn.state = .Configuration
    case PluginMessagePacket:
        // empty
    case ClientInformationPacket:
        // from here on, send server configuration until we reach a serverbound finish config ack
        enqueue_packet(state.io_ctx, client_conn, PluginMessagePacket {
            channel = "minecraft:brand",
            // TODO: hand crafted for now, will we store the payload as a NetworkBuffer in the future?
            // payload for minecraft:brand is a length prefixed string
            payload = { len("crux"), 'c', 'r', 'u', 'x' },
        })
        enqueue_packet(state.io_ctx, client_conn, KnownPacksPacket {
            known_packs = {
                { namespace = "minecraft", id = "core", version = "1.21.10" },
            },
        })
    case KnownPacksPacket:
        ensure_has_core: for pack, i in packet.known_packs {
            if pack.namespace != "minecraft" && pack.id != "core" {
                if i == len(packet.known_packs) - 1 {
                    kick_reason := text_component("No mutual minecraft:core known packs", TextColor(0xffaacc), {.Bold})
                    _kick_client(state, client_conn, kick_reason)
                    break ensure_has_core
                }
            }
        }
        
        // TODO: send remaining registries with nil data if known pack minecraft:core is present
        _send_registry_data(state.io_ctx, client_conn)
        
        enqueue_packet(state.io_ctx, client_conn, FinishConfigurationPacket {})
    case AcknowledgeFinishConfigurationPacket:
        client_conn.state = .Play
        enqueue_packet(state.io_ctx, client_conn, LoginPacket {
            entity_id = 2,
            is_hardcore = false,
            dimension_names = {Identifier("minecraft:overworld")},
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
        enqueue_packet(state.io_ctx, client_conn, SynchronizePlayerPositionPacket {
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
        session_data := _get_session(state, client_conn)
        
        add_player_action := PlayerInfoUpdateActionAddPlayer {
            username = session_data.game_profile.username,
            properties = {},
        }
        gamemode_change := PlayerInfoUpdateActionUpdateGameMode {
            new_mode = .Spectator,
        }
        add_to_tablist := PlayerInfoUpdateActionUpdateListed { listed=true }
        enqueue_packet(state.io_ctx, client_conn, PlayerInfoUpdatePacket {
            players = {
                { uuid = session_data.game_profile.uuid, actions = { add_player_action, gamemode_change, add_to_tablist } },
            },
        })
        enqueue_packet(state.io_ctx, client_conn, PlayerAbilitiesPacket {
            flags = {.AllowFlying, .Flying},
            flying_speed = 0.05,
            fov_modifier = 0.1,
        })
        enqueue_packet(state.io_ctx, client_conn, StartWaitingForChunks {})
    case PlayerLoadedPacket:
        // empty
    case KeepAlivePlayPacket:
        last_keepalive := &client_conn.clientbound_keepalive
        if !last_keepalive.awaiting_serverbound {
            _kick_client(state, client_conn, text_component("Unexpected keepalive", .Red))
            return
        }
        if packet.id != Long(last_keepalive.id) {
            _kick_client(state, client_conn, text_component("Keepalive id mismatch", .Red))
            return
        }
        last_keepalive.awaiting_serverbound = false
    }
}

@(private="file")
_get_session :: proc(state: ^NetworkWorkerState, client_conn: ^ClientConnection) -> ^SessionData {
    assert(client_conn.state > .Status, "attempted to get unexistent session in wrong client state")
    return &state.sessions[client_conn.socket]
}

@(private="file")
_send_registry_data :: proc(io_ctx: ^reactor.IOContext, client_conn: ^ClientConnection) {
    assert(client_conn.state == .Configuration)
    enqueue_packet(io_ctx, client_conn, DimensionTypeRegistry {
        entries = {
            0 = { id = Identifier("minecraft:overworld"), data = nil },
        },
    })
    enqueue_packet(io_ctx, client_conn, CatVariantRegistry {
        entries = {
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
        },
    })
    enqueue_packet(io_ctx, client_conn, ChickenVariantRegistry {
        entries = {
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        },
    })
    enqueue_packet(io_ctx, client_conn, CowVariantRegistry {
        entries = {
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        },
    })
    enqueue_packet(io_ctx, client_conn, FrogVariantRegistry {
        entries = {
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        },
    })
    enqueue_packet(io_ctx, client_conn, PigVariantRegistry {
        entries = {
            { id = Identifier("minecraft:cold"), data = nil },
            { id = Identifier("minecraft:temperate"), data = nil },
            { id = Identifier("minecraft:warm"), data = nil },
        },
    })
    enqueue_packet(io_ctx, client_conn, WolfVariantRegistry {
        entries = {
            { id = Identifier("minecraft:ashen"), data = nil },
            { id = Identifier("minecraft:black"), data = nil },
            { id = Identifier("minecraft:chestnut"), data = nil },
            { id = Identifier("minecraft:pale"), data = nil },
            { id = Identifier("minecraft:rusty"), data = nil },
            { id = Identifier("minecraft:snowy"), data = nil },
            { id = Identifier("minecraft:spotted"), data = nil },
            { id = Identifier("minecraft:striped"), data = nil },
            { id = Identifier("minecraft:woods"), data = nil },
        },
    })
    enqueue_packet(io_ctx, client_conn, WolfSoundVariantRegistry {
        entries = {
            { id = Identifier("minecraft:angry"), data = nil },
            { id = Identifier("minecraft:big"), data = nil },
            { id = Identifier("minecraft:classic"), data = nil },
            { id = Identifier("minecraft:cute"), data = nil },
            { id = Identifier("minecraft:grumpy"), data = nil },
            { id = Identifier("minecraft:puglin"), data = nil },
            { id = Identifier("minecraft:sad"), data = nil },
        },
    })
    enqueue_packet(io_ctx, client_conn, PaintingVariantRegistry {
        entries = {
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
        },
    })
    enqueue_packet(io_ctx, client_conn, DamageTypeRegistry {
        entries = {
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
        },
    })
    // a minecraft:plains biome is required as default biome before a login packet will be accepted
    enqueue_packet(io_ctx, client_conn, BiomeRegistry {
        entries = {
            { id = Identifier("minecraft:plains"), data = nil },
        },
    })
}

// Kicks a client with a message, begins client termination.
@(private="file")
_kick_client :: proc(state: ^NetworkWorkerState, client_conn: ^ClientConnection, reason: TextComponent) {
    // TODO: add DisconnectLoginPacket and implement TextComponent -> json
    #partial switch client_conn.state {
    case .Configuration: 
        enqueue_packet(state.io_ctx, client_conn, DisconnectConfigurationPacket { reason = reason })
    case .Play:
        enqueue_packet(state.io_ctx, client_conn, DisconnectPlayPacket { reason = reason })
    case:
        panic(#procedure + " in wrong client state")
    }
    client_conn.terminating = true
}

// Shuts down and unregisters a connection from all subsystems, and deallocates it.
@(private="file")
_finalize_client :: proc(state: ^NetworkWorkerState, client_conn: ClientConnection) {
    tracy.Zone()
    // ensure termination has been initiated and pending work is flushed, otherwise we would leak memory
    // and risk terminal packets not being sent.
    assert(_should_finalize_disconnect(client_conn))

    // FIXME: probably want to handle error
    reactor.unregister_client(state.io_ctx, client_conn.socket)
    _delete_client_connection(client_conn.socket)

    _, client_conn := delete_key(&state.connections, client_conn.socket)
    delete_key(&state.sessions, client_conn.socket) // if present
    destroy_network_buf(client_conn.tx_buf)
    destroy_network_buf(client_conn.rx_buf)
    
    // ensure right allocator is used to free buffer, instead of panic allocator
    scratch_alloc := cast(^mem.Scratch) client_conn.packet_scratch_alloc.data
    scratch_alloc.backup_allocator = os.heap_allocator()
    mem.scratch_destroy(scratch_alloc)
    free(scratch_alloc, os.heap_allocator())
}
