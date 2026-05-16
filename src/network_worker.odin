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
}

// TODO: logger is not threadsafe
_network_worker_proc :: proc(shared: ^NetworkWorkerSharedData) {
    tracy.SetThreadName("crux-NetWorker")
    state := NetworkWorkerState {
        shared = shared^,
        connections = make(map[net.TCP_Socket]ClientConnection, 16, os.heap_allocator()),
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

        REACTOR_TIMEOUT_MS :: 1
        #assert(REACTOR_TIMEOUT_MS < WORKER_TARGET_MSPT)

        completions: [512]reactor.Completion
        // NOTE: do not indefinitely block or this thread can't be joined
        // TODO: scale down timer resolution when no clients are connected
        nready, await_ok := reactor.await_io_completions(state.io_ctx, completions[:], timeout_ms=REACTOR_TIMEOUT_MS)
        assert(await_ok, "failed to await io events") // TODO: proper error handling

        for comp in completions[:nready] {
            client_conn := &state.connections[comp.socket]
            if client_conn == nil && comp.operation != .NewConnection && comp.operation != .PeerHangup && comp.operation == .Error {
                // stale completion arrived after a disconnect was issued (peer hangup confirmation, io completion
                // that could not be canceled in time or an allocated written back passed back to deallocate)
                continue
            }
            tracy.ZoneN("ProcessCompletion")

            switch comp.operation {
            case .Error:
                log.debug("client socket error")
                // if caused by a write operation, free our allocated submission which was returned back to us
                if comp.buf != nil {
                    delete(comp.buf, client_conn.packet_scratch_alloc)
                }
                if client_conn != nil {
                    _disconnect_client(&state, client_conn^)
                }
            case .PeerHangup:
                log.debug("client socket hangup")
                // client_conn is nil when we disconnected from the peer first, thus only serving as a confirmation
                if client_conn != nil {
                    _disconnect_client(&state, client_conn^)
                }
            case .Read:
                defer reactor.release_recv_buf(state.io_ctx, comp)
                if client_conn.close_after_flushing {
                    // TODO: we need closing logic here?
                    continue
                }
                buf_write_bytes(&client_conn.rx_buf, comp.buf) // copies
                _drain_serverbound_packets(&state, client_conn)
            case .Write:
                // must be freed using the same allocator the reactor write call was made with
                delete(comp.buf, client_conn.packet_scratch_alloc)
                if client_conn.close_after_flushing {
                    log.debug("disconnecting client as requested")
                    _disconnect_client(&state, client_conn^)
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
}

@(private="file")
_network_worker_atexit :: proc(state: ^NetworkWorkerState) {
    for _, client_conn in state.connections {
        _disconnect_client(state, client_conn)
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
            _disconnect_client(state, client_conn^)
            break loop
        case .None:
            packet_desc := get_serverbound_packet_descriptor(packet)
            if packet_desc.expected_client_state != client_conn.state {
                log.debugf("client sent packet in wrong client state (%v != %v): %v", client_conn.state, packet_desc.expected_client_state, packet)
                _disconnect_client(state, client_conn^)
                break loop
            }

            _handle_clientbound_packet(state, packet, client_conn)
            success := chan.try_send(state.packet_bridge, packet)
            if !success {
                // TODO: do we even need a channel, what about a futex/atomic mutex and a darray?
                log.error("tried sending packet to main thread but channel buf is full")
            }
            if client_conn.close_after_flushing do break loop
        }
    }
}

_handle_clientbound_packet :: proc(state: ^NetworkWorkerState, packet: ServerBoundPacket, client_conn: ^ClientConnection) {
    log.log(LOG_LEVEL_INBOUND, "Received Packet", packet)

    switch packet in packet {
    case HandshakePacket:
        client_conn.state = ClientState(packet.intent) // safe to cast
    case LegacyServerListPingPacket:
        log.debugf("kicking client due to LegacyServerPingEvent")
        _disconnect_client(state, client_conn^)
        return

    case StatusRequestPacket:
        status_response := StatusResponsePacket {
            version = {
                name = "1.21.8",
                protocol = .V1_21_8,
            },
            players = {
                max = 100,
                // TODO: when multiply clients are querying server info, this is incorrect
                online = len(state.connections) - 1, // account for querying client
            },
            description = text_component("Some Server", .DarkAqua),
            favicon = "data:image/png;base64,<data>",
            enforces_secure_chat = false,
        }
        enqueue_packet(state.io_ctx, client_conn, status_response)
    case PingRequestPacket:
        response := PongResponsePacket { payload = packet.payload }
        enqueue_packet(state.io_ctx, client_conn, response)
        client_conn.close_after_flushing = true
    case LoginStartPacket:
        // FIXME: negotiate compression here

        // TODO: fetch skin here
        response := LoginSuccessPacket {
            uuid = packet.uuid,
            username = packet.username,
            name = "textures",
            value = "somestringhere",
            signature = nil,
        }
        enqueue_packet(state.io_ctx, client_conn, response)
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
                { namespace = "minecraft", id = "core", version = "1.21.8" },
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
        _send_registry_packets(state.io_ctx, client_conn)
        
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
    }
}

@(private="file")
_send_registry_packets :: proc(io_ctx: ^reactor.IOContext, client_conn: ^ClientConnection) {
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
}

_kick_client :: proc(state: ^NetworkWorkerState, client_conn: ^ClientConnection, reason: TextComponent) {
    assert(client_conn.state == .Configuration, "TODO: handle respective kick packets for other states")
    enqueue_packet(state.io_ctx, client_conn, DisconnectConfigurationPacket { reason = reason })
    client_conn.close_after_flushing = true
}

// Unregisters a client and shuts down the connection without transmitting any more data.
_disconnect_client :: proc(state: ^NetworkWorkerState, client_conn: ClientConnection) {
    tracy.Zone()

    // FIXME: probably want to handle error
    reactor.unregister_client(state.io_ctx, client_conn.socket)
    _delete_client_connection(client_conn.socket)

    _, client_conn := delete_key(&state.connections, client_conn.socket)
    destroy_network_buf(client_conn.tx_buf)
    destroy_network_buf(client_conn.rx_buf)
    
    // ensure right allocator is used to free buffer, instead of panic allocator
    scratch_alloc := cast(^mem.Scratch) client_conn.packet_scratch_alloc.data
    scratch_alloc.backup_allocator = os.heap_allocator()
    mem.scratch_destroy(scratch_alloc)
    free(scratch_alloc, os.heap_allocator())
}
