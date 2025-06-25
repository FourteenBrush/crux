package crux

import "core:time"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "base:runtime"
import "core:encoding/json"

import "src:reactor"

// import "lib:tracy"

TARGET_TPS :: 20

// Worker thread responsable for network related things like performing
// IO on client sockets, (de)serializing and transmission of packets.

// All members are explicitly owned by this thread, unless specified otherwise.
_NetworkWorkerState :: struct {
    io_ctx: reactor.IOContext,
    // Non-blocking server socket.
    server_sock: net.TCP_Socket,
    // An allocator to be used by this thread, the upstream must provide
    // a threadsafe allocator if it is going to used by other threads too.
    threadsafe_alloc: mem.Allocator,
    // Ptr to atomic bool, indicating whether to continue running, modified upstream
    execution_permit: ^bool,

    // ClientConnections shared with the main thread, protected by mutex
    client_connections_guarded_: ^map[net.TCP_Socket]ClientConnection,
    client_connections_mtx: sync.Atomic_Mutex,
}

_network_worker_proc :: proc(state: _NetworkWorkerState) {
    state := state
    defer cleanup: {
        log.debug("shutting down worker")
        // destroy temp alloc when this refers to the default one (thread_local)
        if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
            runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        }
    }
    allocator := state.threadsafe_alloc
    log.debug("Network Worker entrypoint")

    for sync.atomic_load(state.execution_permit) {
        // tracy.ZoneN("WORKER FRAME_IMPL")

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
        // do not indefinitely block or this thread can't be joined
        nready, ok := reactor.await_io_events(&state.io_ctx, &events, timeout_ms=10)
        assert(ok, "failed to await io events") // TODO: proper error handling

        recv_buf: [1024]u8
        for event in events[:nready] {
            if .Readable in event.flags {
                if event.client == state.server_sock {
                    // new socket, the only events that we receive on the server sock
                    _accept_client(&state, allocator=allocator) or_continue
                    continue
                }

                n, recv_err := net.recv_tcp(event.client, recv_buf[:])

                switch {
                case recv_err == net.TCP_Recv_Error.Timeout: continue
                case recv_err != nil:
                    log.warn("error reading from client socket:", recv_err)
                    _disconnect_client(&state, event.client)
                    continue
                case n == 0: // EOF
                    _disconnect_client(&state, event.client)
                    log.info("client disconnected")
                    continue
                case:
                    sync.atomic_mutex_lock(&state.client_connections_mtx)
                    client_conn := state.client_connections_guarded_[event.client]
                    sync.atomic_mutex_unlock(&state.client_connections_mtx)

                    push_data(&client_conn.net_buf, recv_buf[:n])
                    _drain_serverbound_packets(&state, &client_conn, packet_alloc=allocator)
                }
            }
            if .Writable in event.flags {
                // TODO: check if data is batched, and perform write
                // log.debug("client socket is available for writing")
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
    log.debug("shutting down worker thread...")
}

// Called when a new connection is available on the server socket, never blocks.
// Acquires a lock on the client connections.
_accept_client :: proc(state: ^_NetworkWorkerState, allocator: mem.Allocator) -> (ok: bool) {
    client_sock, client_endpoint, accept_err := net.accept_tcp(state.server_sock)
    if accept_err != nil {
        log.warn("failed to accept client:", accept_err)
        return false
    }

    if !reactor.register_client(&state.io_ctx, client_sock) {
        net.close(client_sock)
        log.error("failed to register client")
        return false
    }

    {
        sync.atomic_mutex_guard(&state.client_connections_mtx)
        state.client_connections_guarded_[client_sock] = ClientConnection {
            socket = client_sock,
            net_buf = create_network_buf(allocator=allocator),
            state = .Handshake,
        }
    }
    log.debugf(
        "client %s:%d connected (fd %d)",
        net.address_to_string(client_endpoint.address, context.temp_allocator), client_endpoint.port, client_sock,
    )
    return true
}

// Unregisters a client from the reactor and shuts down the connection.
_disconnect_client :: proc(state: ^_NetworkWorkerState, client_sock: net.TCP_Socket) {
    // FIXME: probably want to handle error
    reactor.unregister_client(&state.io_ctx, client_sock)
    {
        sync.atomic_mutex_guard(&state.client_connections_mtx)
        delete_key(state.client_connections_guarded_, client_sock)
    }
    net.close(client_sock)
}

_drain_serverbound_packets :: proc(state: ^_NetworkWorkerState, client_conn: ^ClientConnection, packet_alloc: mem.Allocator) {
    loop: for {
        packet, err := read_serverbound(&client_conn.net_buf, allocator=packet_alloc)
        switch err {
        case .ShortRead:
            log.debug("short read on packet:")
            dump_network_buffer(client_conn.net_buf)
            break loop
        case .InvalidData:
            log.debug("client sent malformed packet, kicking")
            _disconnect_client(state, client_conn.socket)
            break loop
        case .None:
            dump_network_buffer(client_conn.net_buf)
            _handle_packet(state, packet, client_conn)
        }
    }
}

// FIXME: store sock in client conn struct?
_handle_packet :: proc(state: ^_NetworkWorkerState, packet: ServerboundPacket, client_conn: ^ClientConnection) {
    if _, ok := packet.(LegacyServerListPingPacket); ok {
        log.debugf("kicking client due to LegacyServerPingEvent")
        _disconnect_client(state, client_conn.socket)
        return
    }

    if handshake, ok := packet.(HandshakePacket); ok && handshake.intent == .Status {
        log.infof("client state switched %s -> %s", client_conn.state, handshake.intent)
        client_conn.state = .Status
    } else if _, ok := packet.(StatusRequestPacket); ok {
        // send json
        status_response := StatusResponsePacket {
            versionName = "1.21.5",
            versionProtocol = 770,
            players = {
                max = 100,
                online = 1,
            },
            description = {
                text = "Some server",
            },
            favicon = "data:image/png;base64,<data>",
            enforcesSecureChat = false,
        }
        bytes, m_err := json.marshal(status_response, allocator=context.temp_allocator)
        log.info(string(bytes))
        assert(m_err == nil)
        // n, send_err := net.send(event.client, bytes)
        // assert(n == len(bytes) && send_err == nil)
    }
}
