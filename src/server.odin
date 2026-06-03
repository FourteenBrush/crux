package crux

import "core:os"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"
import "core:thread"
import "core:c/libc"
import "core:strings"
import "core:container/queue"
import "core:encoding/base64"

import "src:reactor"

import "lib:tracy"

PROTOCOL_VERSION :: ProtocolVersion.V1_21_10
GAME_VERSION_STR :: "1.21.10"

// TODO: consider proper packet handling rate while also using a normal minecraft tick model
TARGET_TPS :: 20 * 10

VIEW_DISTANCE :: 8

@(private="file")
server: Server

@(private="file")
g_continue_running := true

// because treesitter highlighting in IDEs breaks when you declare a nested generic type with nesting level > 2, lovely
@(private="file")
InboundMessage :: BridgeMessage(ServerBoundPacket)
@(private="file")
OutboundMessage :: BridgeMessage(ClientBoundPacket)

@(private)
Server :: struct {
    inbound_queue: ^SPSC(InboundMessage),
    outbound_queue: ^SPSC(OutboundMessage),
    messages_emitted: bool,
    
    // World data essentially, TODO: move this out to some world abstraction once this is established
    sessions: map[net.TCP_Socket]SessionData,
}

run :: proc(endpoint: net.Endpoint, server_sock: net.TCP_Socket) -> bool {
    io_ctx := _setup_io_context(server_sock, os.heap_allocator()) or_return
    defer reactor.destroy_io_context(&io_ctx, os.heap_allocator())

    inbound_queue: SPSC(BridgeMessage(ServerBoundPacket))
    queue.init(&inbound_queue.data, 128)
    defer queue.destroy(&inbound_queue.data)
    server.inbound_queue = &inbound_queue
    
    outbound_queue: SPSC(BridgeMessage(ClientBoundPacket))
    queue.init(&outbound_queue.data, 128)
    defer queue.destroy(&outbound_queue.data)
    server.outbound_queue = &outbound_queue
    
    server.sessions = make(map[net.TCP_Socket]SessionData, 16, os.heap_allocator())
    defer delete(server.sessions)

    net_worker_state := NetworkWorkerSharedData {
       io_ctx = &io_ctx,
       server_sock = server_sock,
       execution_permit = &g_continue_running,
       outbound_queue=server.inbound_queue,
       inbound_queue=server.outbound_queue,
    }

    init_context := context
    init_context.allocator = mem.panic_allocator()
    // TODO: logger is not threadsafe
    init_context.logger = create_logger(LOG_LEVEL, {.Level, .Terminal_Color}, "io")
    net_worker_thread := thread.create_and_start_with_poly_data(&net_worker_state, _network_worker_thread_proc, init_context=init_context)
    if net_worker_thread == nil {
        log.fatal("failed to start worker thread")
        return false
    }

    // ensure all allocators are explicitly used
    context.allocator = mem.panic_allocator()

    libc.signal(libc.SIGINT, sig_handler)
    libc.signal(libc.SIGTERM, sig_handler)
    
    log.info("Listening on", net.endpoint_to_string(endpoint))

    for sync.atomic_load_explicit(&g_continue_running, .Acquire) {
        _main_thread_run_tick(&io_ctx)
    }

    log.info("shutting down server...")
    // wakeup io thread from possible infinite sleep
    reactor.wakeup(&io_ctx)
    thread.join(net_worker_thread)
    thread.destroy(net_worker_thread)

    return true
}

@(private="file")
_setup_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: reactor.IOContext, ok: bool) {
    defer if !ok {
        log.error("failed to create io context")
    }
    return reactor.create_io_context(server_sock, allocator)
}

@(private="file")
sig_handler :: proc "c" (_sig: i32) {
    @(static) shutting_down := false
    if sync.atomic_compare_exchange_strong(&shutting_down, false, true) do return
    sync.atomic_store_explicit(&g_continue_running, false, .Release)
}

@(private="file")
_main_thread_run_tick :: proc(io_ctx: ^reactor.IOContext) {
    defer tracy.FrameMark()
    start := time.tick_now()

    for message in spsc_dequeue(server.inbound_queue) {
        _handle_bridge_message(&server, message)
    }
    if server.messages_emitted {
        reactor.wakeup(io_ctx)
        server.messages_emitted = false
    }
    _handle_keepalives(&server)
    
    free_all(context.temp_allocator)

    // TODO: we may not necessarily want to use a tick resolution of 50ms (minecraft tick), but instead
    // use a higher resolution and just emulate minecraft ticks to be multiple of those ticks.
    // This would prevent baseline packet response times to be 50ms already.
    tick_duration := time.tick_since(start)
    target_tick_time :: 1000 / TARGET_TPS * time.Millisecond
    if tick_duration < target_tick_time {
        //log.debug("tick time", tick_duration, "sleeping", target_tick_time - tick_duration)
        time.sleep(target_tick_time - tick_duration)
    }
}

@(private="file")
_handle_bridge_message :: proc(server: ^Server, message: InboundMessage) {
    switch message in message {
    case TerminateClientRequest:
        session := (&server.sessions[message.client]) or_break
        // TODO: do we just remove the session or set a terminating flag and do this later on?

        // TODO: actually remove connection from map, we still sent data allocated by this thread to the io thread
        // but this can be fixed by using a global epoch based allocator, whereas the session now doesnt
        // store any interesting state that must be retained
        session.terminating = true
        scratch_alloc := cast(^mem.Scratch) session.packet_scratch_alloc.data
        if len(scratch_alloc.leaked_allocations) > 0 {
            log.warn("Leaked the following allocations into heap allocator:")
            for entry in scratch_alloc.leaked_allocations {
                log.warnf("- %M", len(entry))
            }
        }
    case PacketTransfer(ServerBoundPacket):
        _handle_serverbound_packet(server, message.packet, message.socket)
    }
}

@(private="file")
_handle_keepalives :: proc(server: ^Server) {
    // send keepalive packets, required every 1-15 secs, disconnect after 20 secs
    KEEPALIVE_INTERVAL :: 13 * time.Second
    KEEPALIVE_TIMEOUT :: 20 * time.Second
    // FIXME: would ideally base this off world ticks instead of monotonic clock syscalls
    now := time.tick_now()
    
    for _, &session in server.sessions {
        if session.state != .Play || session.terminating do continue
        
        last_keepalive := &session.clientbound_keepalive
        elapsed := time.tick_diff(last_keepalive.sent, now)
        if last_keepalive.awaiting_serverbound {
            if elapsed > KEEPALIVE_TIMEOUT {
                _kick_client(server, &session, text_component("Timed out", .Red))
                continue
            }
        } else if elapsed > KEEPALIVE_INTERVAL {
            id := i64(elapsed)
            enqueue_packet(&session, KeepAlivePlayPacket { id=Long(id) })
            last_keepalive.sent = now
            last_keepalive.id = id
            last_keepalive.awaiting_serverbound = true
        }
    }
}

@(private)
_create_session :: proc(
    socket: net.TCP_Socket,
    state: ClientState,
    protocol_version: ProtocolVersion,
) -> SessionData {
    // scratch_alloc := new(mem.Mutex_Allocator, os.heap_allocator())
    // mem.mutex_allocator_init(scratch_alloc, os.heap_allocator())
    scratch_alloc := new(mem.Scratch, os.heap_allocator())
    mem.scratch_init(scratch_alloc, 256 * 1024, os.heap_allocator())
    
    return SessionData {
        socket=socket,
        state=state,
        protocol_version=protocol_version,
        // packet_scratch_alloc=mem.mutex_allocator(scratch_alloc),
        packet_scratch_alloc=mem.scratch_allocator(scratch_alloc),
    }
}

// TODO: never called
@(private)
_terminate_session :: proc(server: ^Server, session: SessionData) {
    assert(session.terminating)
    delete_key(&server.sessions, session.socket)
    
    spsc_enqueue(server.outbound_queue, TerminateClientRequest { client=session.socket })
    
    scratch_alloc := cast(^mem.Scratch) session.packet_scratch_alloc.data
    mem.scratch_destroy(scratch_alloc)
    free(scratch_alloc, os.heap_allocator())
}

// Kicks a client with a message, enters a termination state.
@(private)
_kick_client :: proc(server: ^Server, session: ^SessionData, reason: TextComponent) {
    #partial switch session.state {
    case .Login:
        enqueue_packet(session, DisconnectLoginPacket { reason = reason })
    case .Configuration: 
        enqueue_packet(session, DisconnectConfigurationPacket { reason = reason })
    case .Play:
        enqueue_packet(session, DisconnectPlayPacket { reason = reason })
    case:
        panic(#procedure + " called in client state which does not permit disconnect packets")
    }
    session.terminating = true
}

@(private)
enqueue_packet :: proc(session: ^SessionData, packet: ClientBoundPacket) {
    descriptor := get_clientbound_packet_descriptor(packet)
    assert(session != nil)
    if session.terminating do return
    
    spsc_enqueue(server.outbound_queue, PacketTransfer(ClientBoundPacket) { socket=session.socket, packet=packet })
    session.terminating |= descriptor.is_terminal
    server.messages_emitted = true
    // log.warn("MAIN THREAD: enqueued packet", packet)
}

@(private)
_load_favicon :: proc() -> string {
    @(static) favicon_encoded: string
    
    if favicon_encoded == "" {
        prefix :: "data:image/png;base64,"
        sb := strings.builder_make(os.heap_allocator())
        fmt.sbprint(&sb, prefix, sep="")
        base64.encode_into(strings.to_writer(&sb), #load("../favicon.png"))
        favicon_encoded = strings.to_string(sb)
    }
    return favicon_encoded
}