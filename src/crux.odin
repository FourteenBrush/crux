package crux

import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"

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

    io_ctx, ok := create_io_context()
    if !ok {
        return fatal("failed to create io context")
    }
    defer destroy_io_context(&io_ctx)

    server := Server {
        io_ctx = io_ctx,
        client_connections = make(map[net.Address]ClientConnection, 16, allocator),
        client_socks_to_addr = make(map[net.TCP_Socket]net.Address, 16, allocator),
    }

    for sync.atomic_load_explicit(&g_running, .Acquire) {
        defer tracy.FrameMark()
        start := time.tick_now()

        frame_impl: {
            tracy.ZoneN("FRAME_IMPL")
            exitcode := accept_connections(server_sock, &server, allocator)
            if exitcode != 0 do return exitcode

            exitcode = process_incoming_packets(&server, allocator)
            if exitcode != 0 do return exitcode
        }
        free_all(context.temp_allocator)

        tick_duration := time.tick_since(start)
        // TODO: bug in odin compiler, doesnt let me use :: here
        target_tick_time :: 1000 / TARGET_TPS * time.Millisecond
        if tick_duration < target_tick_time {
            //log.debug("tick time", tick_duration, "sleeping", target_tick_time - tick_duration)
            time.sleep(target_tick_time - tick_duration)
        }
    }
    
    return 0
}

accept_connections :: proc(server_sock: net.TCP_Socket, server: ^Server, allocator: mem.Allocator) -> ExitCode {
    // FIXME: perhaps do some timeframing here
    for {
        // TODO: net.accept sets socket TCP_NODELAY by default (or based on ODIN_NET_TCP_NODELAY_DEFAULT)
        // which makes every write one IP packet, implement buffering ourselves,
        client_sock, source, accept_err := net.accept_tcp(server_sock)
        // TODO: close on disconnect
        if accept_err == net.Accept_Error.Would_Block {
            // server socket is marked non-blocking, no available connections
            break
        } else if accept_err != nil {
            log.warn("failed to accept client:", accept_err)
            continue
        }

        register_client_: {
            tracy.ZoneN("ACCEPT_CLIENT")
            _, client_conn, is_new_client, _ := map_entry(&server.client_connections, source.address)
            if !is_new_client {
                log.warnf("client %d connected again", source.address)
                net.close(client_sock)
                continue
            }

            if !register_client(&server.io_ctx, client_sock) {
                net.close(client_sock)
                return fatal("failed to register client")
            }
            // TODO: linux.epoll_ctl(epoll_fd, .DEL, linux.Fd(client_sock), nil) on disconnect

            client_conn^ = ClientConnection {
                buf = create_network_buf(allocator=allocator),
                state = .Handshake,
            }
            server.client_socks_to_addr[client_sock] = source.address
            log.debugf(
                "client %s:%d connected (fd %d)",
                net.address_to_string(source.address, context.temp_allocator), source.port, client_sock,
            )
        }
    }

    return 0
}

process_incoming_packets :: proc(server: ^Server, allocator: mem.Allocator) -> ExitCode {
    events: [512]Event
    nready, ok := await_io_events(&server.io_ctx, &events, timeout=0)
    if !ok {
        return fatal("failed to await io events")
    }

    recv_buf: [1024]u8
    for event in events[:nready] {
        if .In in event.flags {
            n, recv_err := net.recv_tcp(event.client, recv_buf[:])
            switch {
            case recv_err == net.TCP_Recv_Error.Timeout: // EWOULDBLOCK
                // why is there no data but the socket is available for read() operations? anyways..
                continue
            case recv_err != nil:
                log.warn("error reading from client socket:", recv_err)
                handle_client_disconnect(server, event.client)
                continue
            case n == 0:
                log.info("client disconnected")
                handle_client_disconnect(server, event.client)
                continue
            case:
                // this is stupid
                client_addr := server.client_socks_to_addr[event.client]
                client_conn := server.client_connections[client_addr]
                // TODO: make worker thread form packet, acquire thread boundary lock and
                // push them to packet queue of client
                push_data(&client_conn.buf, recv_buf[:n])
                packet, ok := read_serverbound(&client_conn.buf, allocator)
                if !ok {
                    // NOTE: server attempts to send a legacy server list ping packet
                    // when normal ping times out (30s)
                    log.error("failed to read serverbound packet")
                    continue
                } else {
                    log.info(packet)
                }
            }
        } else if .Out in event.flags {
            // TODO
            log.debug("client socket is available for writing")
        } else if .Err in event.flags {
            log.warn("client socket error")
            handle_client_disconnect(server, event.client)
        } else if .Hup in event.flags {
            log.warn("client socket hangup")
            handle_client_disconnect(server, event.client)
        }
    }

    return 0
}

handle_client_disconnect :: proc(server: ^Server, client_sock: net.TCP_Socket) {
    _, addr := delete_key(&server.client_socks_to_addr, client_sock)
    delete_key(&server.client_connections, addr)
    // FIXME: probably want to handle error
    unregister_client(&server.io_ctx, client_sock)
}

Server :: struct {
    io_ctx: IOContext,
    client_connections: map[net.Address]ClientConnection,
    // TODO: rather stupud way to go indirectly from io ctx associated data
    // to the client data, via client_connections (2 lookups)
    // Perhaps generate some uuid from the start??
    // is a net.TCP_Socket alone unique if we simply disallow multiple connections from the same address?
    client_socks_to_addr: map[net.TCP_Socket]net.Address,
}

ClientConnection :: struct {
    // TODO: only for reading from client; implement write buffering
    buf: NetworkBuffer,
    state: ClientState,
}

ClientState :: enum VarInt {
    Handshake = 0,
    Status    = 1,
    Login     = 2,
    Transfer  = 3,
}
