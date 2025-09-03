// Worker thread responsable for network related things like performing
// IO on client sockets, (de)serialization and transmission of packets.
package crux

import "core:fmt"
import "core:time"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "base:runtime"
import "core:sync/chan"

import "src:reactor"

import "lib:tracy"

TARGET_TPS :: 20

NetworkWorkerSharedData :: struct {
    io_ctx: reactor.IOContext,
    // Non-blocking server socket.
    server_sock: net.TCP_Socket,
    // An allocator to be used by this thread, must be owned by this thread or be thread safe.
    threadsafe_alloc: mem.Allocator,
    // Ptr to atomic bool, indicating whether to continue running, modified upstream
    execution_permit: ^bool,
    packet_bridge: chan.Chan(Packet, .Send),
}

// All members are explicitly owned by this thread, unless specified otherwise.
@(private="file")
NetworkWorkerState :: struct {
    using shared: NetworkWorkerSharedData,
    connections: map[net.TCP_Socket]ClientConnection,
}

_network_worker_proc :: proc(shared: ^NetworkWorkerSharedData) {
    tracy.SetThreadName("crux-Networker")
    state := NetworkWorkerState {
        shared = shared^,
        connections = make(map[net.TCP_Socket]ClientConnection, shared.threadsafe_alloc),
    }

    defer cleanup: {
        log.debug("shutting down worker")
        delete(state.connections)
        // destroy temp alloc when this refers to the default one (thread_local)
        if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
            runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        }
    }

    for sync.atomic_load(state.execution_permit) {
        // TODO: do we need the network thread to be tps bound?
        start := time.tick_now()
        defer {
            tick_duration := time.tick_since(start)
            target_tick_time := 1000 / TARGET_TPS * time.Millisecond
            if tick_duration < target_tick_time {
                tracy.ZoneNC("Worker Sleep", color=0x9c4433)
                time.sleep(target_tick_time - tick_duration)
            }
            free_all(context.temp_allocator)
            tracy.FrameMark("Worker")
        }

        events: [512]reactor.Event
        // NOTE: do not indefinitely block or this thread can't be joined
        nready, ok := reactor.await_io_events(&state.io_ctx, events[:], timeout_ms=5)
        assert(ok, "failed to await io events") // TODO: proper error handling

        for event in events[:nready] {
            fmt.println(event)

            if .Error in event.operations {
                log.warn("client socket error")
                _disconnect_client(&state, event.socket)
                continue
            } else if .Hangup in event.operations {
                log.warn("client socket hangup")
                _disconnect_client(&state, event.socket)
                continue
            }

            if .Read in event.operations {
                client_conn := &state.connections[event.socket]
                buf_write_bytes(&client_conn.rx_buf, event.recv_buf)
                _drain_serverbound_packets(&state, client_conn, state.threadsafe_alloc)
            }
            if .Write in event.operations {
                client_conn := &state.connections[event.socket]
                // buf_advance_pos_unchecked(&client_conn.tx_buf, event.nr_of_bytes_affected)

                if client_conn.close_after_flushing {
                    log.debug("disconnecting client as requested")
                    _disconnect_client(&state, client_conn.socket)
                }
            }
            if .NewClient in event.operations {
                state.connections[event.socket] = ClientConnection {
                    socket = event.socket,
                    state  = .Handshake,
                    rx_buf = create_network_buf(allocator=state.threadsafe_alloc),
                    tx_buf = create_network_buf(allocator=state.threadsafe_alloc),
                }

                log.debugf("client connected (fd %d)", event.socket)
            }
        }
    }
}

_drain_serverbound_packets :: proc(state: ^NetworkWorkerState, client_conn: ^ClientConnection, packet_alloc: mem.Allocator) {
    loop: for {
        packet, err := read_serverbound(&client_conn.rx_buf, client_conn.state, allocator=packet_alloc)
        switch err {
        case .ShortRead:
            if buf_length(client_conn.rx_buf) > 0 {
                log.debug("short read on packet")
            }
            break loop
        case .InvalidData:
            log.debug("client sent malformed packet, kicking; buf=")
            buf_dump(client_conn.rx_buf)
            _disconnect_client(state, client_conn.socket)
            break loop
        case .None:
            packet_desc := get_serverbound_packet_descriptor(packet)
            if packet_desc.expected_client_state != client_conn.state {
                log.debugf("client sent packet in wrong client state (%v != %v): %v", client_conn.state, packet_desc.expected_client_state, packet)
                _disconnect_client(state, client_conn.socket)
                break loop
            }

            _handle_packet(state, packet, client_conn)
            success := chan.try_send(state.packet_bridge, packet)
            if !success {
                // TODO: do we even need a channel, what about a futex/atomic mutex and a darray?
                log.error("tried sending packet to main thread but channel buf is full")
            }
        }
    }
}

_handle_packet :: proc(state: ^NetworkWorkerState, packet: ServerBoundPacket, client_conn: ^ClientConnection) {
    log.log(LOG_LEVEL_INBOUND, "Received Packet", packet)

    switch packet in packet {
    case HandshakePacket:
        client_conn.state = ClientState(packet.intent) // safe to cast
    case LegacyServerListPingPacket:
        log.debugf("kicking client due to LegacyServerPingEvent")
        _disconnect_client(state, client_conn.socket)
        return

    // TODO: move to main thread
    case StatusRequestPacket:
        status_response := StatusResponsePacket {
            version = {
                name = "1.21.6",
                protocol = .V1_21_6,
            },
            players = {
                max = 100,
                online = 2,
            },
            description = {
                text = "Some server",
            },
            favicon = "data:image/png;base64,<data>",
            enforces_secure_chat = false,
        }
        enqueue_packet(&state.io_ctx, client_conn, status_response, allocator=state.threadsafe_alloc)
    case PingRequestPacket:
        response := PongResponsePacket {
            payload = packet.payload,
        }
        enqueue_packet(&state.io_ctx, client_conn, response, allocator=state.threadsafe_alloc)
        client_conn.close_after_flushing = true
    case LoginStartPacket:
        response := LoginSuccessPacket {
            uuid = packet.uuid,
            username = packet.username,
            name = "",
            value = "",
            signature = nil,
        }
        enqueue_packet(&state.io_ctx, client_conn, response, allocator=state.threadsafe_alloc)
    case LoginAcknowledgedPacket:
        client_conn.state = .Configuration
    }
}

// Unregisters a client from the reactor and shuts down the connection.
_disconnect_client :: proc(state: ^NetworkWorkerState, client_sock: net.TCP_Socket) {
    // FIXME: probably want to handle error
    reactor.unregister_client(&state.io_ctx, client_sock)
    _delete_client_connection(client_sock)
    net.close(client_sock)
}
