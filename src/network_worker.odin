// Worker thread responsable for network related things like performing
// IO on client sockets, (de)serialization and transmission of packets.
package crux

import "core:time"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "base:runtime"
import "core:sync/chan"

import "src:reactor"

// import "lib:tracy"

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
    state := NetworkWorkerState {
        shared = shared^,
        connections = make(map[net.TCP_Socket]ClientConnection, shared.threadsafe_alloc),
    }
    
    defer cleanup: {
        log.debug("shutting down worker")
        delete(state.connections)
        // spall.buffer_destroy(&g_spall_ctx, &g_spall_buf)
        // destroy temp alloc when this refers to the default one (thread_local)
        if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
            runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        }
    }

    allocator := state.threadsafe_alloc

    {
        // initialize spall for this thread
        // backing_buf := make([]u8, spall.BUFFER_DEFAULT_SIZE, state.threadsafe_alloc)
        // g_spall_buf = spall.buffer_create(backing_buf, u32(sync.current_thread_id()))
    }
    // spall.SCOPED_EVENT(&g_spall_ctx, &g_spall_buf, "Network Worker entrypoint")

    for sync.atomic_load(state.execution_permit) {
        // tracy.ZoneN("WORKER FRAME_IMPL")

        // TODO: do we need the network thread to be tps bound?
        start := time.tick_now()
        defer {
            tick_duration := time.tick_since(start)
            target_tick_time := 1000 / TARGET_TPS * time.Millisecond
            if tick_duration < target_tick_time {
                time.sleep(target_tick_time - tick_duration)
            }
            // tracy.FrameMark()
            free_all(context.temp_allocator)
        }

        events: [512]reactor.Event
        // NOTE: do not indefinitely block or this thread can't be joined
        nready, ok := reactor.await_io_events(&state.io_ctx, &events, timeout_ms=5)
        assert(ok, "failed to await io events") // TODO: proper error handling

        recv_buf: [1024]u8
        for event in events[:nready] {
            if .Readable in event.flags {
                if event.client == state.server_sock {
                    // new socket, the only events that we receive on the server sock
                    _accept_client(&state) or_continue
                    continue
                }

                n, recv_err := net.recv_tcp(event.client, recv_buf[:])

                switch {
                case recv_err == net.TCP_Recv_Error.Timeout: continue
                case recv_err != .None:
                    log.warn("error reading from client socket:", recv_err)
                    _disconnect_client(&state, event.client)
                    continue
                case n == 0: // EOF
                    _disconnect_client(&state, event.client)
                    log.info("client disconnected")
                    continue
                case:
                    client_conn := &state.connections[event.client]
                    buf_write_bytes(&client_conn.rx_buf, recv_buf[:n])
                    _drain_serverbound_packets(&state, client_conn, allocator)
                }
            }
            if .Writable in event.flags {
                client_conn := &state.connections[event.client]
                
                if buffered := buf_length(client_conn.tx_buf); buffered > 0 {
                    // FIXME: may we need a TEMP_ALLOCATOR_GUARD() here?
                    outb := make([]u8, buffered, context.temp_allocator)
                    read_err := buf_copy_into(&client_conn.tx_buf, outb)
                    assert(read_err == .None, "invariant, copied full length")
                    n, send_err := net.send_tcp(event.client, outb)
                    #partial switch send_err {
                    case nil, .Would_Block:
                        // kernel buf might not be able to hold full data, send remaining data next time
                        // (send_tcp() calls send() repeatedly in a loop, till any error occurs)
                        buf_advance_pos_unchecked(&client_conn.tx_buf, n)
                    case:
                        log.warn("error writing to client socket:", send_err)
                        _disconnect_client(&state, client_conn.socket)
                        continue
                    }
                    
                    if client_conn.close_after_flushing {
                        log.debug("disconnecting client as requested")
                        _disconnect_client(&state, client_conn.socket)
                    }
                }
            }
            if .Err in event.flags {
                log.warn("client socket error")
                _disconnect_client(&state, event.client)
            } else if .Hangup in event.flags {
                log.warn("client socket hangup")
                _disconnect_client(&state, event.client)
            }
        }
    }
}

_drain_serverbound_packets :: proc(state: ^NetworkWorkerState, client_conn: ^ClientConnection, packet_alloc: mem.Allocator) {
    loop: for {
        packet, err := read_serverbound(&client_conn.rx_buf, client_conn.state, allocator=packet_alloc)
        switch err {
        case .ShortRead:
            if len(client_conn.rx_buf.data) > 0 {
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
        enqueue_packet(client_conn, status_response, allocator=state.threadsafe_alloc)
    case PingRequestPacket:
        response := PongResponsePacket {
            payload = packet.payload,
        }
        enqueue_packet(client_conn, response, allocator=state.threadsafe_alloc)
        client_conn.close_after_flushing = true
    case LoginStartPacket:
        response := LoginSuccessPacket {
            uuid = packet.uuid,
            username = packet.username,
            name = "",
            value = "",
            signature = nil,
        }
        enqueue_packet(client_conn, response, allocator=state.threadsafe_alloc)
    case LoginAcknowledgedPacket:
        client_conn.state = .Configuration
    }
}

// Called when a new connection is available on the server socket, never blocks.
_accept_client :: proc(state: ^NetworkWorkerState) -> (ok: bool) {
    client_sock, client_endpoint, accept_err := net.accept_tcp(state.server_sock)
    if accept_err != nil {
        log.warn("failed to accept client:", accept_err)
        return false
    }
    
    if net.set_blocking(client_sock, false) != .None {
        log.error("failed to set client socket as non blocking")
        return false
    }
    
    client_conn := map_insert(&state.connections, client_sock, ClientConnection {
        socket = client_sock,
        state = .Handshake,
    })

    if !reactor.register_client(&state.io_ctx, client_sock) {
        log.error("failed to register client")
        net.close(client_sock)
        return false
    }
    
    // in case reactor registration fails
    client_conn.rx_buf = create_network_buf(allocator=state.threadsafe_alloc)
    client_conn.tx_buf = create_network_buf(allocator=state.threadsafe_alloc)

    log.debugf(
        "client %s:%d connected (fd %d)",
        net.address_to_string(client_endpoint.address, context.temp_allocator), client_endpoint.port, client_sock,
    )
    return true
}

// Unregisters a client from the reactor and shuts down the connection.
_disconnect_client :: proc(state: ^NetworkWorkerState, client_sock: net.TCP_Socket) {
    // FIXME: probably want to handle error
    reactor.unregister_client(&state.io_ctx, client_sock)
    _delete_client_connection(client_sock)
    net.close(client_sock)
}
