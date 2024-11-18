package crux

import "core:c"
import "core:os"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"
import "core:c/libc"

import "core:sys/linux"
import "core:prof/spall"

import "base:runtime"

_ :: mem
_ :: sync
_ :: spall
_ :: runtime

ExitCode :: int

when ODIN_DEBUG {
    @(thread_local)
    g_spall_buf: spall.Buffer
    g_spall_ctx: spall.Context
}

main :: proc() {
    when ODIN_DEBUG {
        allocator: mem.Tracking_Allocator
        mem.tracking_allocator_init(&allocator, context.allocator)
        defer mem.tracking_allocator_destroy(&allocator)
        context.allocator = mem.tracking_allocator(&allocator)

        defer {
            for _, leak in allocator.allocation_map {
                fmt.printfln("%v leaked %m", leak.location, leak.size)
            }
            for bad_free in allocator.bad_free_array {
                fmt.printfln("%v allocation %p was freed badly", bad_free.location, bad_free.memory)
            }
        }

        g_spall_ctx = spall.context_create("trace.spall") or_else panic("failed to setup spall")
        defer spall.context_destroy(&g_spall_ctx)

        backing_buf := make([]u8, spall.BUFFER_DEFAULT_SIZE)
        g_spall_buf = spall.buffer_create(backing_buf, u32(sync.current_thread_id()))
        defer spall.buffer_destroy(&g_spall_ctx, &g_spall_buf)
    }
    
    exitcode: ExitCode
    // NOTE: must be put before all other deferred statements
    defer os.exit(exitcode)

    log_opts := log.Options {.Level, .Thread_Id, .Terminal_Color}
    for &header in log.Level_Headers {
        header = header[:len(header) - len("---  ")]
    }

    context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Warning, log_opts)
    defer log.destroy_console_logger(context.logger)

    libc.signal(libc.SIGINT, proc "c" (_: i32) {
        spall_fd := g_spall_ctx.fd
        context = runtime.default_context()
        _ = os.flush(spall_fd)
    })

    args, ok := parse_cli_args()
    log.info(args, ok)

    exitcode = run()
}

run :: proc(allocator := context.allocator) -> ExitCode {
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

    for /* is_running */ {
        start := time.tick_now()
        defer {
            tick_duration := time.tick_since(start)
            // TODO: bug in odin compiler, doesnt let me use :: here
            target_tick_time := 1000 / 20 * time.Millisecond // assuming 20 tps
            if tick_duration < target_tick_time {
                //log.debug("tick time", tick_duration, "sleeping", target_tick_time - tick_duration)
                time.sleep(target_tick_time - tick_duration)
            }
        }

        if spall.SCOPED_EVENT(&g_spall_ctx, &g_spall_buf, "frame") {
            exitcode := accept_connections(server_sock, &conn_man)
            if exitcode != 0 do return exitcode

            exitcode = process_incoming_packets(&conn_man)
            if exitcode != 0 do return exitcode
        }
    }
    
    return 0
}

accept_connections :: proc(server_sock: net.TCP_Socket, conn_man: ^ConnectionManager) -> ExitCode {
    for {
        client_sock, source, accept_err := net.accept_tcp(server_sock)
        // TODO: close on disconnect
        if accept_err == net.Accept_Error.Would_Block do break // TODO: sure about this?
        else if accept_err != nil {
            return fatal("failed to accept client:", accept_err)
        }

        trace("client accept()")
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
            socket = client_sock,
            reader = create_packet_reader(),
        }
        log.debugf("got a request from %v, client fd=%d", source, linux.Fd(client_sock))
    }

    return 0
}

process_incoming_packets :: proc(conn_man: ^ConnectionManager) -> ExitCode {
    events: [128]linux.EPoll_Event

    // block for half a tick at most (assuming 20 tps)
    // TODO: overhead occurs here when epoll_wait has no data available and has to wait for the 
    // whole timeout
    nready, epoll_err := linux.epoll_wait(conn_man.epoll_fd, &events[0], len(events), 0)
    if epoll_err != nil {
        return fatal("epoll_wait() failed:", epoll_err)
    }

    recv_buf: [1024]u8
    for event in events[:nready] {
        if event.events != .IN do continue

        client_fd := event.data.fd
        assert(client_fd > 0, "epoll_ctl did not pass fd correctly")
        socket := net.TCP_Socket(client_fd)
        n, net_err := net.recv_tcp(socket, recv_buf[:])

        switch {
        case net_err != nil: return fatal("error reading from client socket", net_err)
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
        // TODO: make worker thread form packet, acquire thread boundary lock and
        // push them to packet queue of client
        push_data(&client_conn.reader, recv_buf[:n])

        ensure_readable(client_conn.reader, size_of(PacketHeader)) or_continue
        // attempt to read a packet
        // TODO: main threads responsability
        length := read_var_int(&client_conn.reader) or_continue
        _ = ensure_readable(client_conn.reader, length)

        id := read_var_int(&client_conn.reader) or_continue
        if transmute(PacketId) id == .Handshake {
            protocol_version := read_var_int(&client_conn.reader) or_continue
            server_addr_len := read_var_int(&client_conn.reader) or_continue
            // TODO: read server_addr
            next_state := ConnectionState(read_var_int(&client_conn.reader) or_continue)
            fmt.println(protocol_version, server_addr_len, next_state)
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

ClientConnection :: struct {
    socket: net.TCP_Socket,
    // TODO: come up with a better name
    reader: PacketReader,
}

// Logs a fatal condition, which we cannot recover from.
// This proc always returns 1, for the sake of `return fatal("aa")`
@(require_results)
fatal :: proc(args: ..any, loc := #caller_location) -> ExitCode {
    log.fatal(..args, location=loc)
    return 1
}

@(no_instrumentation)
trace :: #force_inline proc(name := "", args := "", loc := #caller_location) {
    when ODIN_DEBUG {
        spall.SCOPED_EVENT(&g_spall_ctx, &g_spall_buf, name, args, loc)
    }
}

when ODIN_DEBUG {
    @(instrumentation_enter)
    spall_enter :: proc "contextless" (proc_addr, call_site_ret_addr: rawptr, loc: runtime.Source_Code_Location) {
        spall._buffer_begin(&g_spall_ctx, &g_spall_buf, "", "", loc)
    }

    @(instrumentation_exit)
    spall_exit :: proc "contextless" (proc_addr, call_site_ret_addr: rawptr, loc: runtime.Source_Code_Location) {
        spall._buffer_end(&g_spall_ctx, &g_spall_buf)
    }
}
