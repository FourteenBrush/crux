package crux

import "core:os"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"
import "core:thread"
import "core:sync/chan"

import "src:reactor"

import "lib:tracy"

TARGET_TPS :: 20

@(private="file")
g_server: Server

@(private="file")
Server :: struct {
    _client_connections_guarded: map[net.TCP_Socket]ClientConnection,
    _client_connections_mtx: sync.Ticket_Mutex,
    packet_receiver: chan.Chan(Packet, .Recv),
}

// Inputs:
// - `execution_permit`: an atomic bool indicating whether to continue running
run :: proc(execution_permit: ^bool) -> bool {
    endpoint := net.Endpoint {
        address = net.IP4_Loopback,
        port = 25565,
    }

    server_sock := _setup_server_socket(endpoint) or_return
    defer net.close(server_sock)

    io_ctx := _setup_io_context(server_sock, os.heap_allocator()) or_return
    defer reactor.destroy_io_context(&io_ctx, os.heap_allocator())

    g_server._client_connections_guarded = make(map[net.TCP_Socket]ClientConnection)
    defer _destroy_server(g_server)

    packet_receiver, alloc_err := chan.create_buffered(chan.Chan(Packet, .Both), 512, context.allocator)
    if alloc_err != .None {
        return fatal("failed to create packet channel", alloc_err)
    }
    defer chan.destroy(packet_receiver)
    g_server.packet_receiver = chan.as_recv(packet_receiver)

    net_worker_state := NetworkWorkerSharedData {
       io_ctx = io_ctx,
       server_sock = server_sock,
       execution_permit = execution_permit,
       packet_bridge = chan.as_send(packet_receiver),
    }

    net_worker_thread: ^thread.Thread
    init_context := context
    init_context.allocator = mem.panic_allocator()
    net_worker_thread = thread.create_and_start_with_poly_data(&net_worker_state, _network_worker_proc, init_context=init_context)
    if net_worker_thread == nil {
        return fatal("failed to start worker thread")
    }

    // ensure all allocators are explicitly used
    context.allocator = mem.panic_allocator()

    for sync.atomic_load_explicit(execution_permit, .Acquire) {
        defer tracy.FrameMark()
        start := time.tick_now()

        for packet in chan.try_recv(g_server.packet_receiver) {
            _ = packet
            // log.warn("MAIN THREAD:", packet)
        }
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

// Creates a new client with all default data.
register_client_connection :: proc(client_sock: net.TCP_Socket) {
    sync.ticket_mutex_guard(&g_server._client_connections_mtx)

    g_server._client_connections_guarded[client_sock] = ClientConnection {
        socket = client_sock,
        state = .Handshake,
    }
}

// Deletes a client connection from the server, it must be first unregistered from the various subsystems.
// This call is threadsafe and is only supposed to be called by higher level components.
@(private)
_delete_client_connection :: proc(client_sock: net.TCP_Socket) -> ClientConnection {
    sync.ticket_mutex_guard(&g_server._client_connections_mtx)
    _, conn := delete_key(&g_server._client_connections_guarded, client_sock)
    return conn
}

@(private="file")
_setup_server_socket :: proc(endpoint: net.Endpoint) -> (net.TCP_Socket, bool) {
    sock, net_err := net.listen_tcp(endpoint, backlog=75)
    if net_err != nil {
        log.errorf("failed to create server socket: %s", net_err)
        return sock, false
    }

    net_err = net.set_blocking(sock, false)
    if net_err != nil {
        log.errorf("failed to set server socket to non blocking: %s", net_err)
        net.close(sock)
        return sock, false
    }
    return sock, true
}

@(private="file")
_setup_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (reactor.IOContext, bool) {
    io_ctx, ctx_ok := reactor.create_io_context(server_sock, allocator)
    if !ctx_ok {
        log.error("failed to create io context")
        return io_ctx, false
    }
    return io_ctx, true
}

@(private="file")
_destroy_server :: proc(server: Server) {
    // TODO: do we need to acquire some mutex here just to be sure?
    delete(server._client_connections_guarded)
}

ClientConnection :: struct {
    // Non blocking socket
    socket: net.TCP_Socket,
    state: ClientState,

    // Whether this connection needs to be closed after flushing all packets
    close_after_flushing: bool,
    rx_buf: NetworkBuffer,
    tx_buf: NetworkBuffer,
}

// IMPORTANT NOTE: values must match respective values from HandshakeIntent to allow casting
ClientState :: enum VarInt {
    Handshake,
    Status        = auto_cast HandshakeIntent.Status,
    Login         = auto_cast HandshakeIntent.Login,
    Transfer      = auto_cast HandshakeIntent.Transfer,
    Configuration,
}

// Logs a fatal condition, which we cannot recover from.
// This proc always returns false, for the sake of `return fatal("message")`
@(require_results, private)
fatal :: proc(args: ..any, loc := #caller_location) -> bool {
    log.fatal(..args, location=loc)
    return false
}