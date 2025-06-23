package crux

import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"
import "core:encoding/json"

import "src:reactor"

import "lib:tracy"

TARGET_TPS :: 20

// FIXME: fix scope
@(private)
g_running := true

run :: proc(allocator: mem.Allocator) -> ExitCode {
    endpoint := net.Endpoint {
        address = net.IP4_Loopback,
        port = 25565,
    }

    server_sock, net_err := net.listen_tcp(endpoint)
    if net_err != nil {
        return fatal("failed to create server socket:", net_err)
    }
    defer net.close(server_sock)

    net_err = net.set_blocking(server_sock, false)
    if net_err != nil {
        return fatal("failed to set socket to non blocking", net_err)
    }

    io_ctx, ok := reactor.create_io_context()
    if !ok {
        return fatal("failed to create io context")
    }
    defer reactor.destroy_io_context(&io_ctx)

    server := Server {
        io_ctx = io_ctx,
        client_connections = make(map[net.TCP_Socket]ClientConnection, 16, allocator),
    }

    for sync.atomic_load_explicit(&g_running, .Acquire) {
        defer tracy.FrameMark()
        start := time.tick_now()

        frame_impl: {
            // tracy.ZoneN("FRAME_IMPL")
            exitcode := accept_connections(server_sock, &server, allocator)
            if exitcode != 0 do return exitcode

            exitcode = process_incoming_packets(&server, allocator)
            if exitcode != 0 do return exitcode
        }
        free_all(context.temp_allocator)

        tick_duration := time.tick_since(start)
        target_tick_time :: 1000 / TARGET_TPS * time.Millisecond
        if tick_duration < target_tick_time {
            //log.debug("tick time", tick_duration, "sleeping", target_tick_time - tick_duration)
            time.sleep(target_tick_time - tick_duration)
        }
    }

    return 0
}

accept_connections :: proc(server_sock: net.TCP_Socket, server: ^Server, allocator: mem.Allocator) -> ExitCode {
    for {
        // TODO: net.accept sets socket TCP_NODELAY by default (or based on ODIN_NET_TCP_NODELAY_DEFAULT)
        // which makes every write one IP packet, implement buffering ourselves,
        client_sock, client_endpoint, accept_err := net.accept_tcp(server_sock)
        if accept_err == net.Accept_Error.Would_Block {
            // server socket is marked non-blocking, no available connections
            break
        } else if accept_err != nil {
            log.warn("failed to accept client:", accept_err)
            continue
        }

        register_client: {
            // tracy.ZoneN("ACCEPT_CLIENT")

            // NOTE: we cannot differentiate between individual sockets or client endpoints being the same client
            // we shouldn't because we are only at handshaking state, and NAT is a thing,

            if !reactor.register_client(&server.io_ctx, client_sock) {
                net.close(client_sock)
                log.error("failed to register client")
                continue
            }
            server.client_connections[client_sock] = ClientConnection {
                read_buf = create_network_buf(allocator=allocator),
                state = .Handshake,
            }
            log.debugf(
                "client %s:%d connected (fd %d)",
                net.address_to_string(client_endpoint.address, context.temp_allocator), client_endpoint.port, client_sock,
            )
        }
    }

    return 0
}

process_incoming_packets :: proc(server: ^Server, allocator: mem.Allocator) -> ExitCode {
    events: [512]reactor.Event
    nready, ok := reactor.await_io_events(&server.io_ctx, &events, timeout_ms=5)
    if !ok {
        return fatal("failed to await io events")
    }

    recv_buf: [1024]u8
    for event in events[:nready] {
        if .Readable in event.flags {
            n, recv_err := net.recv_tcp(event.client, recv_buf[:])
            log.info(recv_buf[:n])
            switch {
            case recv_err == net.TCP_Recv_Error.Timeout: // EWOULDBLOCK
                // why is there no data but the socket is available for read() operations? anyways..
                continue
            case recv_err != nil:
                log.warn("error reading from client socket:", recv_err)
                disconnect_client(server, event.client)
                continue
            case n == 0: // EOF
                disconnect_client(server, event.client)
                log.info("client disconnected")
                continue
            case:
                client_conn := server.client_connections[event.client]
                push_data(&client_conn.read_buf, recv_buf[:n])
                packet, read_err := read_serverbound(&client_conn.read_buf, allocator)
                if read_err != .None {
                    log.error("failed to read serverbound packet")
                    continue
                }

                log.info(packet)
                // TODO: dispatch packet back to main thread, unless LegacyServerPingPacket (i think)
                if _, ok := packet.(LegacyServerPingPacket); ok {
                    log.debugf("kicking client due to LegacyServerPingEvent")
                    disconnect_client(server, event.client)
                    continue
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
        }
        if .Writable in event.flags {
            // TODO: check if data is batched, and perform write
            // log.debug("client socket is available for writing")
        }
        if .Err in event.flags {
            log.warn("client socket error")
            disconnect_client(server, event.client)
        } else if .Hangup in event.flags {
            log.warn("client socket hangup")
            disconnect_client(server, event.client)
        }
    }

    return 0
}

// Unregisters a client from the reactor and shuts down the connection.
disconnect_client :: proc(server: ^Server, client_sock: net.TCP_Socket) {
    delete_key(&server.client_connections, client_sock)
    // FIXME: probably want to handle error
    reactor.unregister_client(&server.io_ctx, client_sock)
    net.close(client_sock)
}

Server :: struct {
    io_ctx: reactor.IOContext,
    client_connections: map[net.TCP_Socket]ClientConnection,
}

ClientConnection :: struct {
    // TODO: only for reading from client; implement write buffering
    read_buf: NetworkBuffer,
    state: ClientState,
}

ClientState :: enum VarInt {
    Handshake = 0,
    Status    = 1,
    Login     = 2,
    Transfer  = 3,
}
