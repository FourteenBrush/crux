package crux

import "core:time"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "base:runtime"
import "core:sys/posix"

import "src:reactor"

// import "lib:tracy"

// TODO: add support for others
when ODIN_OS == .Linux {
    foreign import pthread "system:c"
}

foreign pthread {
    when ODIN_OS == .Linux {
        pthread_setname_np :: proc(posix.pthread_t, cstring) -> posix.Errno ---
    } else when ODIN_OS == .OpenBSD {
        pthread_set_name_np :: proc(self: posix.pthread_t, copied_name: cstring) ---
    } else when ODIN_OS == .FreeBSD {
        pthread_set_name_np :: proc(posix.pthread_t, cstring) -> posix.Errno ---
    }
}

TARGET_TPS :: 20

// Worker thread responsable for network related things like performing
// IO on client sockets, (de)serialization and transmission of packets.

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
    defer cleanup: {
        log.debug("shutting down worker")
        // destroy temp alloc when this refers to the default one (thread_local)
        if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
            runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        }
    }

    state := state
    allocator := state.threadsafe_alloc
    log.debug("Network Worker entrypoint")
    _try_set_threadname()

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
                case recv_err != .None:
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

                    buf_write_bytes(&client_conn.rx_buf, recv_buf[:n])
                    _drain_serverbound_packets(&state, &client_conn, packet_alloc=allocator)
                }
            }
            if .Writable in event.flags {
                // TODO: might want to do this a little more efficiently, as Writable events are
                // continuously spammed, can we make only this flag level triggered?

                // additionally, cant we store a stable ref to the client connection in the event,
                // instead of storing the socket, and still having to acquire a lock to obtain the conn?
                sync.atomic_mutex_lock(&state.client_connections_mtx)
                client_conn := state.client_connections_guarded_[event.client]
                sync.atomic_mutex_unlock(&state.client_connections_mtx)

                if buffered := buf_length(client_conn.tx_buf); buffered > 0 {
                    outb := make([]u8, buffered, context.temp_allocator)
                    read_err := buf_read_bytes(&client_conn.tx_buf, outb)
                    assert(read_err == .None, "invariant, bytes suddenly not available anymore?")
                    _, send_err := net.send_tcp(event.client, outb)
                    switch {
                    // TODO: rollback, kernel buf is full?
                    case send_err == .Would_Block: continue
                    case send_err != nil:
                        log.warn("error writing to client socket:", send_err)
                        _disconnect_client(&state, client_conn.socket)
                        continue
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

@(disabled=ODIN_OS != .Linux)
_try_set_threadname :: proc() {
    // NOTE: must not be longer than 16 chars (including \0)
    if errno := pthread_setname_np(posix.pthread_self(), "crux-NetWorker"); errno != .NONE {
        log.warnf("failed to set worker thread name; err=%d", errno)
    }
}

// Called when a new connection is available on the server socket, never blocks.
// Acquires a lock on the client connections.
_accept_client :: proc(state: ^_NetworkWorkerState, allocator: mem.Allocator) -> (ok: bool) {
    client_sock, client_endpoint, accept_err := net.accept_tcp(state.server_sock)
    if accept_err != nil {
        log.warn("failed to accept client:", accept_err)
        return false
    }
    
    // TODO: handle network errors properly
    assert(net.set_blocking(client_sock, false) == .None, "failed to set client socket as non blocking")

    if !reactor.register_client(&state.io_ctx, client_sock) {
        net.close(client_sock)
        log.error("failed to register client")
        return false
    }

    if sync.atomic_mutex_guard(&state.client_connections_mtx) {
        state.client_connections_guarded_[client_sock] = ClientConnection {
            socket = client_sock,
            rx_buf = create_network_buf(allocator=allocator),
            tx_buf = create_network_buf(allocator=allocator),
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
    if sync.atomic_mutex_guard(&state.client_connections_mtx) {
        delete_key(state.client_connections_guarded_, client_sock)
    }
    net.close(client_sock)
}

_drain_serverbound_packets :: proc(state: ^_NetworkWorkerState, client_conn: ^ClientConnection, packet_alloc: mem.Allocator) {
    loop: for {
        packet, err := read_serverbound(&client_conn.rx_buf, allocator=packet_alloc)
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
            _handle_packet(state, packet, client_conn)
        }
    }
}

// FIXME: move packet processing to main thread
_handle_packet :: proc(state: ^_NetworkWorkerState, packet: ServerboundPacket, client_conn: ^ClientConnection) {
    log.info(packet)

    switch packet in packet {
    case HandshakePacket:
        if packet.intent != .Status {
            log.info("received handshake with intent", packet.intent)
            _disconnect_client(state, client_conn.socket)
            return
        }
        client_conn.state = .Status
    case LegacyServerListPingPacket:
        log.debugf("kicking client due to LegacyServerPingEvent")
        _disconnect_client(state, client_conn.socket)
        return
        
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
            // favicon = "data:image/png;base64,<data>",
            // enforces_secure_chat = false,
        }
        _ = enqueue_packet(client_conn, status_response, allocator=state.threadsafe_alloc)
    case PingRequest:
        response := PongResponse {
            payload = packet.payload,
        }
        _ = enqueue_packet(client_conn, response, allocator=state.threadsafe_alloc)
        // TODO: this  relies on the fact enqueue_packet send them directly, we would be closing before
        // the packets were send otherwise
        _disconnect_client(state, client_conn.socket)
    }
}
