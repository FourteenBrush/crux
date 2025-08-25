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

// All members are explicitly owned by this thread, unless specified otherwise.
_NetworkWorkerState :: struct {
    io_ctx: reactor.IOContext,
    // Non-blocking server socket.
    server_sock: net.TCP_Socket,
    // An allocator to be used by this thread, must be owned by this thread or be thread safe.
    threadsafe_alloc: mem.Allocator,
    // Ptr to atomic bool, indicating whether to continue running, modified upstream
    execution_permit: ^bool,
    connections: map[net.TCP_Socket]ClientConnection,
    packet_bridge: chan.Chan(Packet, .Send),
}

_network_worker_proc :: proc(state: ^_NetworkWorkerState) {
    defer cleanup: {
        log.debug("shutting down worker")
        // destroy temp alloc when this refers to the default one (thread_local)
        if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
            runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        }
    }

    allocator := state.threadsafe_alloc
    log.debug("Network Worker entrypoint")
    _try_set_threadname()

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
                    _accept_client(state) or_continue
                    continue
                }

                n, recv_err := net.recv_tcp(event.client, recv_buf[:])

                switch {
                case recv_err == net.TCP_Recv_Error.Timeout: continue
                case recv_err != .None:
                    log.warn("error reading from client socket:", recv_err)
                    _disconnect_client(state, event.client)
                    continue
                case n == 0: // EOF
                    _disconnect_client(state, event.client)
                    log.info("client disconnected")
                    continue
                case:
                    client_conn := &state.connections[event.client]
                    buf_write_bytes(&client_conn.rx_buf, recv_buf[:n])
                    // attempt to read any complete packets
                    _drain_serverbound_packets(state, client_conn, allocator)
                }
            }
            if .Writable in event.flags {
                // TODO: might want to do this a little more efficiently, as Writable events may be
                // continuously spammed every "server tick", can we make only this flag level triggered?

                client_conn := &state.connections[event.client]
                if client_conn == nil {
                    // client might be disconnected but reactor events might have still been on the way
                    log.debugf("received reactor events on disconnected client (%v)", event.flags)
                    continue
                }
                
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
                        _disconnect_client(state, client_conn.socket)
                        continue
                    }
                    
                    if client_conn.close_after_flushing {
                        log.debug("disconnecting client as requested")
                        _disconnect_client(state, client_conn.socket)
                    }
                }
            }
            if .Err in event.flags {
                log.warn("client socket error")
                _disconnect_client(state, event.client)
            } else if .Hangup in event.flags {
                log.warn("client socket hangup")
                _disconnect_client(state, event.client)
            }
        }
    }
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

_handle_packet :: proc(state: ^_NetworkWorkerState, packet: ServerBoundPacket, client_conn: ^ClientConnection) {
    log.log(LOG_LEVEL_OUTBOUND, "Received Packet", packet)

    switch packet in packet {
    case HandshakePacket:
        client_conn.state = packet.intent
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
        response := PongResponse {
            payload = packet.payload,
        }
        enqueue_packet(client_conn, response, allocator=state.threadsafe_alloc)
        client_conn.close_after_flushing = true
    case LoginStartPacket:
        // TODO
        
        
        
        
        
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
_accept_client :: proc(state: ^_NetworkWorkerState) -> (ok: bool) {
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
_disconnect_client :: proc(state: ^_NetworkWorkerState, client_sock: net.TCP_Socket) {
    // FIXME: probably want to handle error
    reactor.unregister_client(&state.io_ctx, client_sock)
    _delete_client_connection(client_sock)
    net.close(client_sock)
}
