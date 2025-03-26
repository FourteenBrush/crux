package crux

import "core:log"
import "core:mem"
import "core:net"
import "core:time"
import "core:sys/linux"

import "lib:tracy"

TARGET_TPS :: 20
EPOLL_EVENT_BUF_SIZE :: 128

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

    epoll_fd, create_err := linux.epoll_create()
    if create_err != nil {
        return fatal("failed to create epoll fd:", create_err)
    }
    defer linux.close(epoll_fd)

    conn_man := ConnectionManager {
        epoll_fd = epoll_fd,
        client_connections = make(map[linux.Fd]ClientConnection, 16, allocator),
    }

    for g_running {
        defer tracy.FrameMark()
        start := time.tick_now()

        frame_impl: {
            tracy.ZoneN("FRAME_IMPL")
            exitcode := accept_connections(server_sock, &conn_man, allocator)
            if exitcode != 0 do return exitcode

            exitcode = process_incoming_packets(&conn_man, allocator)
            if exitcode != 0 do return exitcode
        }
        free_all(context.temp_allocator)

        tick_duration := time.tick_since(start)
        // TODO: bug in odin compiler, doesnt let me use :: here
        target_tick_time := 1000 / TARGET_TPS * time.Millisecond
        if tick_duration < target_tick_time {
            //log.debug("tick time", tick_duration, "sleeping", target_tick_time - tick_duration)
            time.sleep(target_tick_time - tick_duration)
        }
    }
    
    return 0
}

accept_connections :: proc(server_sock: net.TCP_Socket, conn_man: ^ConnectionManager, allocator: mem.Allocator) -> ExitCode {
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

        accept_client: {
            tracy.ZoneN("ACCEPT_CLIENT")
            event := linux.EPoll_Event {
                events = .IN,
                data = { fd = linux.Fd(client_sock) },
            }

            ctl_err := linux.epoll_ctl(conn_man.epoll_fd, .ADD, linux.Fd(client_sock), &event)
            // TODO: linux.epoll_ctl(epoll_fd, .DEL, linux.Fd(client_sock), nil) on disconnect
            if ctl_err != nil {
                net.close(client_sock)
                return fatal("failed to add client to epoll interest list:", ctl_err)
            }

            conn_man.client_connections[event.data.fd] = ClientConnection {
                buf = create_packet_reader(allocator=allocator),
            }
            log.debugf("got a request from %v, client fd=%d", source, linux.Fd(client_sock))
        }
    }

    return 0
}

process_incoming_packets :: proc(conn_man: ^ConnectionManager, allocator: mem.Allocator) -> ExitCode {
    events: [EPOLL_EVENT_BUF_SIZE]linux.EPoll_Event

    nready, epoll_err := linux.epoll_wait(conn_man.epoll_fd, &events[0], len(events), timeout=0)
    if epoll_err != nil {
        return fatal("epoll_wait() failed:", epoll_err)
    }

    recv_buf: [1024]u8
    for event in events[:nready] {
        if event.events != .IN {
            // TODO: handle other events (also implicit error conditions)
            log.info("unexpected event type", event.events)
            continue
        }

        client_fd := event.data.fd
        assert(client_fd > 0, "epoll_ctl did not pass fd correctly")
        socket := net.TCP_Socket(client_fd)
        // TODO: read all (remaining) available data when n == len(recv_buf)
        n, recv_err := net.recv_tcp(socket, recv_buf[:])

        switch {
        case recv_err == net.TCP_Recv_Error.Timeout: // EWOULDBLOCK
            // we asked for a situation where the socket is available for read() operations,
            // but there's no data, anyways...
            // FIXME: could this also indicate an eof?
            continue
        case recv_err != nil:
            return fatal("error reading from client socket", recv_err)
        case n == 0: // TODO: disconnect, keeps looping cuz eof also means ready
            log.info("client disconnected")
            epoll_err = linux.epoll_ctl(conn_man.epoll_fd, .DEL, client_fd, nil)
            if epoll_err != nil {
                return fatal("failed to diconnect client from epoll interest set:", epoll_err)
            }
            delete_key(&conn_man.client_connections, client_fd)
            continue
        }
    
        client_conn := conn_man.client_connections[client_fd]
        reader := &client_conn.buf
        // TODO: make worker thread form packet, acquire thread boundary lock and
        // push them to packet queue of client
        push_data(reader, recv_buf[:n])

        packet, ok := read_serverbound(reader, allocator)
        if !ok {
            log.error("failed to read serverbound packet")
            continue
        } else {
            log.info(packet)
        }
    }

    return 0
}

handle_client_disconnect :: proc() {
    panic("TODO")
}

ConnectionManager :: struct {
    // TODO: are these unique?
    client_connections: map[linux.Fd]ClientConnection,
    epoll_fd: linux.Fd,
}

// TODO: get rid of this struct? store read data instead, dont share this anymore
// with another thread, instead acquire a lock on a shared packet queue
ClientConnection :: struct {
    // TODO: come up with a better name
    buf: NetworkBuffer,
}
