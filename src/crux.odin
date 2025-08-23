package crux

import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"
import "core:thread"

import "src:reactor"

// import "lib:tracy"

// Inputs:
// - `execution_permit`: an atomic bool indicating whether to continue running
run :: proc(threadsafe_alloc: mem.Allocator, execution_permit: ^bool) -> bool {
    endpoint := net.Endpoint {
        address = net.IP4_Loopback,
        port = 25565,
    }

    server_sock := _setup_server_socket(endpoint) or_return
    defer net.close(server_sock)

    io_ctx := _setup_io_context(server_sock) or_return
    defer reactor.destroy_io_context(&io_ctx)

    client_connections := make(map[net.TCP_Socket]ClientConnection, 4, threadsafe_alloc)
    defer delete(client_connections)

    defer if fmt._user_formatters == nil {
        delete(fmt._user_formatters^)
    }
    if fmt._user_formatters == nil {
        formatters := make(map[typeid]fmt.User_Formatter, allocator=threadsafe_alloc)
        fmt.set_user_formatters(&formatters)
    }
    _register_user_formatters(allocator=threadsafe_alloc)

    // spawn network worker, the ownership of members is documented on this type itself
    net_worker_state := _NetworkWorkerState {
       io_ctx = io_ctx,
       server_sock = server_sock,
       threadsafe_alloc = threadsafe_alloc,
       execution_permit = execution_permit,
       client_connections_guarded_ = &client_connections,
       client_connections_mtx = {}, // unlocked
    }

    // FIXME
    orig_context := context
    context.allocator = threadsafe_alloc
    // NOTE: self_cleanup=true detaches the thread, making us unable to join
    net_worker_thread := thread.create_and_start_with_poly_data(net_worker_state, _network_worker_proc, init_context=context, self_cleanup=false)
    if net_worker_thread == nil {
        return fatal("failed to start worker thread")
    }
    context = orig_context

    for sync.atomic_load_explicit(execution_permit, .Acquire) {
        // defer tracy.FrameMark()
        start := time.tick_now()

        // work...
        // free_all(context.temp_allocator)

        tick_duration := time.tick_since(start)
        target_tick_time :: 1000 / TARGET_TPS * time.Millisecond
        if tick_duration < target_tick_time {
            //log.debug("tick time", tick_duration, "sleeping", target_tick_time - tick_duration)
            time.sleep(target_tick_time - tick_duration)
        }
    }

    log.info("shutting down server...")
    thread.join(net_worker_thread)
    thread.destroy(net_worker_thread)

    return true
}

_setup_server_socket :: proc(endpoint: net.Endpoint) -> (net.TCP_Socket, bool) {
    sock, net_err := net.listen_tcp(endpoint, backlog=1000)
    if net_err != nil {
        log.errorf("failed to create server socket: %s", net_err)
        return sock, false
    }

    net_err = net.set_blocking(sock, false)
    if net_err != nil {
        log.errorf("failed to set server socket to non blocking: %s", net_err)
        return sock, false
    }
    return sock, true
}

_setup_io_context :: proc(server_sock: net.TCP_Socket) -> (reactor.IOContext, bool) {
    io_ctx, ctx_ok := reactor.create_io_context()
    if !ctx_ok {
        log.error("failed to create io context")
        return io_ctx, false
    }

    // register server sock to io waitset, so we can simply receive events
    // indicating new clients want to connect, instead of manually calling accept() and such
    register_server_ok := reactor.register_client(&io_ctx, server_sock)
    if !register_server_ok {
        log.error("failed to register server socket to io context")
        reactor.destroy_io_context(&io_ctx)
        return io_ctx, false
    }
    return io_ctx, true
}

_register_user_formatters :: proc(allocator: mem.Allocator) {
    context.allocator = allocator
    fmt.register_user_formatter(Utf16String, proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
        str := (^Utf16String)(arg.data)^
        // TODO: only correctly formatted on some terminals
        fmt.wprintf(fi.writer, "%s", cast([]u8) str)
        return true
    })
}

// Network related client data, this struct is `#no_copy` to prevent bugs
// with modifying copies, FIXME: is this really desired to the outside?
ClientConnection :: struct #no_copy {
    // Non blocking socket
    socket: net.TCP_Socket,
    // Whether this connection needs to be closed after flushing all packets
    close_after_flushing: bool,
    rx_buf: NetworkBuffer,
    tx_buf: NetworkBuffer,
    state: ClientState,
}

ClientState :: enum VarInt {
    Handshake = 0,
    Status    = 1,
    Login     = 2,
    Transfer  = 3,
}

// Logs a fatal condition, which we cannot recover from.
// This proc always returns false, for the sake of `return fatal("aa")`
@(require_results, private)
fatal :: proc(args: ..any, loc := #caller_location) -> bool {
    log.fatal(..args, location=loc)
    return false
}