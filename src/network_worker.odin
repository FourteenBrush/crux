// Worker thread responsable for network related things like performing
// IO on client sockets, (de)serialization and transmission of packets.
package crux

import "core:os"
import "core:time"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "base:runtime"
import "core:container/queue"

import "src:reactor"

import "lib:tracy"

@(private="file")
WORKER_TARGET_MSPT :: 5

// The capacity of the allocator that allocates per client packet specific data, if this allocator
// fills up, old data will be overwritten.
@(private="file")
PACKET_SCRATCH_BUFFER_SIZE :: 256 * 1024

NetworkWorkerSharedData :: struct {
    io_ctx: ^reactor.IOContext,
    // Non-blocking server socket.
    server_sock: net.TCP_Socket,
    // An allocator to be used by this thread, must be owned by this thread or be thread safe.
    threadsafe_alloc: mem.Allocator,
    // Ptr to atomic bool, indicating whether to continue running, modified upstream.
    execution_permit: ^bool,
    // Packet channel to main thread.
    outbound_queue: ^SPSC(BridgeMessage(ServerBoundPacket)),
    inbound_queue: ^SPSC(BridgeMessage(ClientBoundPacket)),
}

// All members are explicitly owned by this thread, unless specified otherwise.
@(private="file")
NetworkWorkerState :: struct {
    using shared: NetworkWorkerSharedData,
    connections: map[net.TCP_Socket]ClientConnection,
}

@(private)
BridgeMessage :: union($P: typeid) #no_nil {
    PacketTransfer(P),
    TerminateClientRequest,
}

@(private)
TerminateClientRequest :: struct {
    client: net.TCP_Socket,
}
    
@(private)
PacketTransfer :: struct($P: typeid) {
    socket: net.TCP_Socket,
    // FIXME: store packet ptr instead, and epoch for recycling
    packet: P,
}

// TODO: make this a wait-free ringbuffer instead of whatever nonsense this is
@(private)
SPSC :: struct($E: typeid) {
    data: queue.Queue(E),
    mutex: sync.Atomic_Mutex,
}

@(private)
spsc_enqueue :: proc(q: ^SPSC($E), elem: E) {
    if sync.guard(&q.mutex) {
        _ = queue.push(&q.data, elem) or_else panic(#procedure + ": OOM")
    }
}

@(private)
spsc_dequeue :: proc(q: ^SPSC($E)) -> (E, bool) {
    if sync.guard(&q.mutex) {
        return queue.pop_front_safe(&q.data)
    }
    unreachable()
}

// IO client context.
@(private="file")
ClientConnection :: struct {
    // Non blocking socket
    socket: net.TCP_Socket,
    state: ClientState,
    // Whether a packet with an `is_terminal = true` flag has been sent or an explicit termination
    // request was issued, this indicates that this connection will be closed shortly
    // and any consecutive `enqueue_packet` calls will silently ignore that packet.
    terminating: bool,
    // Number of outstanding write operations, which has not yet received a completion.
    // This acts as a refcount to the allocator data being stored here, to ensure all writes are properly deallocated.
    // While it is not an issue to just clear the whole allocator at once (effectively getting rid of the writes
    // needing to be deallocated problem), it remains important that we do not close this connection till all
    // writes are flushed (as there may be a terminal packet at the end of the tx buf, which definitely needs to be transferred).
    // When this number reaches zero, and `terminating` is true, this connection will be fully closed and cleaned up.
    outstanding_writes: u32,
    
    // Allocator to deal with all packet related allocations, overwriting itself
    // if there is too much backpressure.
    packet_scratch_alloc: mem.Allocator,

    rx_buf: NetworkBuffer,
    // FIXME: may in fact be a linear buffer as it is always sent at once
    tx_buf: NetworkBuffer,
}

// Whether a ClientConnection may be finalized after receiving a completion.
@(private="file")
_should_finalize_disconnect :: proc(conn: ClientConnection) -> bool {
    return conn.terminating && conn.outstanding_writes == 0
}

@(private)
_network_worker_thread_proc :: proc(shared: ^NetworkWorkerSharedData) {
    tracy.SetThreadName("crux-NetWorker")
    state := NetworkWorkerState {
        shared = shared^,
        connections = make(map[net.TCP_Socket]ClientConnection, 16, os.heap_allocator()),
    }

    defer cleanup: {
        log.debug("shutting down worker")
        _network_worker_atexit(&state)
        // destroy temp alloc when this refers to the default one (thread_local)
        if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
            runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        }
    }

    for sync.atomic_load(state.execution_permit) {
        start := time.tick_now()
        defer {
            tick_duration := time.tick_since(start)
            target_tick_time := WORKER_TARGET_MSPT * time.Millisecond
            if tick_duration < target_tick_time {
                tracy.ZoneNC("Worker Sleep", color=0x9c4433)
                time.sleep(target_tick_time - tick_duration)
            }
            free_all(context.temp_allocator)
            tracy.FrameMark("Worker")
        }

        _network_worker_run_tick(&state)
    }
}

@(private="file")
_network_worker_run_tick :: proc(state: ^NetworkWorkerState) {
    REACTOR_TIMEOUT_MS :: 1
    #assert(REACTOR_TIMEOUT_MS < WORKER_TARGET_MSPT)
    
    // process clientbound packets coming from the main thread
    for message in spsc_dequeue(state.inbound_queue) {
        s: switch message in message {
        case TerminateClientRequest:
            // may be a stale request
            client_conn := (&state.connections[message.client]) or_break s
            client_conn.terminating = true
        case PacketTransfer(ClientBoundPacket):
            client_conn := &state.connections[message.socket]
            if client_conn.terminating do break s
            enqueue_ok := _enqueue_packet(state.io_ctx, client_conn, message.packet)
            if !enqueue_ok {
                client_conn.terminating = true
            }
        }
    }
    
    completions: [512]reactor.Completion
    // TODO: thread sometimes stalls with reactor.TIMEOUT_INFINITE
    nready, await_ok := reactor.await_io_completions(state.io_ctx, completions[:], timeout_ms=reactor.TIMEOUT_INFINITE)
    assert(await_ok, "failed to await io events") // TODO: proper error handling

    for comp in completions[:nready] {
        tracy.ZoneN("ProcessCompletion")
        
        client_conn := &state.connections[comp.socket]
        comp_holds_conn_alive := comp.operation == .Write || (comp.operation == .Error && comp.buf != nil)
        assert(
            client_conn != nil || !comp_holds_conn_alive,
            "completion with outstanding write ownership arrived after ClientConnection destruction",
        )
        if comp_holds_conn_alive {
            assert(client_conn.outstanding_writes > 0)
            client_conn.outstanding_writes -= 1
        }

        switch comp.operation {
        case .Error:
            // FIXME: currently gets spammed for every submitted buffer
            log.debug("client socket error")
            client_conn.terminating = true
            // if caused by a write operation, free our allocated submission which was returned back to us
            if comp.buf != nil {
                delete(comp.buf, client_conn.packet_scratch_alloc)
            }
            if _should_finalize_disconnect(client_conn^) {
                _finalize_client(state, client_conn^)
            }
        case .PeerHangup:
            log.debug("client socket hangup")
            // client_conn is nil when we disconnected from the peer first, thus only serving as a confirmation
            if client_conn != nil {
                client_conn.terminating = true
                if _should_finalize_disconnect(client_conn^) {
                    _finalize_client(state, client_conn^)
                }
            }
        case .Read:
            defer reactor.release_recv_buf(state.io_ctx, comp)
            if client_conn == nil || client_conn.terminating {
                continue
            }
            buf_write_bytes(&client_conn.rx_buf, comp.buf) // copies
            _drain_serverbound_packets(state, client_conn)
        case .Write:
            // must be freed using the same allocator the reactor write call was made with
            delete(comp.buf, client_conn.packet_scratch_alloc)
            if _should_finalize_disconnect(client_conn^) {
                log.debug("disconnecting client as requested")
                _finalize_client(state, client_conn^)
            }
        case .NewConnection:
            state.connections[comp.socket] = _create_client_connection(comp.socket)
            log.info("new connection from", net.endpoint_to_string_allocator(comp.endpoint, context.temp_allocator))
        }
    }
}

@(private="file")
_network_worker_atexit :: proc(state: ^NetworkWorkerState) {
    // TODO: linger to ensure all client bufs are flushed, maybe even send "Server Closed" disconnect packet
    for _, client_conn in state.connections {
        _finalize_client(state, client_conn)
    }
    delete(state.connections)
}

@(private="file")
_drain_serverbound_packets :: proc(state: ^NetworkWorkerState, client_conn: ^ClientConnection) {
    tracy.Zone()

    loop: for {
        packet, err := read_serverbound(&client_conn.rx_buf, client_conn.state, allocator=client_conn.packet_scratch_alloc)
        switch err {
        case .ShortRead: break loop
        case .InvalidData:
            log.debug("client sent malformed packet, kicking; buf=")
            buf_dump(client_conn.rx_buf)
            _kick_client(state, client_conn, text_component_single("Sent an unimplemented packet", TextColor(0xD92625)))
            break loop
        case .None:
            packet_desc := get_serverbound_packet_descriptor(packet)
            if packet_desc.expected_client_state != client_conn.state {
                log.debugf("client sent packet in wrong client state (%v != %v): %v", client_conn.state, packet_desc.expected_client_state, packet)
                _finalize_client(state, client_conn^)
                break loop
            }

            // tap into inbound packets to keep our client state in sync with the main thread
            // TODO: do this in a cleaner way
            #partial switch packet in packet {
            case HandshakePacket: client_conn.state = ClientState(packet.intent) // safe to cast
            case LoginAcknowledgedPacket: client_conn.state = .Configuration
            case AcknowledgeFinishConfigurationPacket: client_conn.state = .Play
            }
            
            message := PacketTransfer(ServerBoundPacket) { socket=client_conn.socket, packet=packet }
            spsc_enqueue(state.outbound_queue, message)
            if client_conn.terminating do break loop
        }
    }
}

// Returns false on failure
@(private="file", require_results)
_enqueue_packet :: proc(io_ctx: ^reactor.IOContext, client_conn: ^ClientConnection, packet: ClientBoundPacket) -> bool {
    tracy.Zone()
    
    // if already terminating, ignore
    if client_conn.terminating do return true

    descriptor := get_clientbound_packet_descriptor(packet)
    log.log(LOG_LEVEL_OUTBOUND, "Sending packet", packet)
    _serialize_clientbound(&client_conn.tx_buf, packet, descriptor)
    
    // freed after receiving write completion
    outb, alloc_err := mem.alloc_bytes_non_zeroed(buf_length(client_conn.tx_buf), align_of(u8), client_conn.packet_scratch_alloc)
    if alloc_err != nil {
        log.debug("failed to allocate write submission buffer:", alloc_err)
        return false
    }

    read_err := buf_copy_into(&client_conn.tx_buf, outb)
    assert(read_err == .None, "invariant, copied full length")

    submission_ok := reactor.submit_write_copy(io_ctx, client_conn.socket, outb)
    if !submission_ok {
        delete(outb, client_conn.packet_scratch_alloc)
        log.debug("io submission not ok")
        return false
    }
    buf_advance_pos_unchecked(&client_conn.tx_buf, len(outb))
    
    client_conn.outstanding_writes += 1
    client_conn.terminating |= descriptor.is_terminal
    return true
}

// Kicks a client with a message, begins client termination.
// TODO: remove this once we have all packets implemented
@(private="file")
_kick_client :: proc(state: ^NetworkWorkerState, client_conn: ^ClientConnection, reason: TextComponent) {
    // NOTE: ignore enqueing failures, we set the connection to terminating either way
    #partial switch client_conn.state {
    case .Login:
        _ = _enqueue_packet(state.io_ctx, client_conn, DisconnectLoginPacket { reason = reason })
    case .Configuration: 
        _ = _enqueue_packet(state.io_ctx, client_conn, DisconnectConfigurationPacket { reason = reason })
    case .Play:
        _ = _enqueue_packet(state.io_ctx, client_conn, DisconnectPlayPacket { reason = reason })
    case:
        panic(#procedure + " called in client state which does not permit disconnect packets")
    }
    client_conn.terminating = true
}

@(private="file")
_create_client_connection :: proc(socket: net.TCP_Socket) -> ClientConnection {
    packet_scratch := new(mem.Mutex_Allocator, os.heap_allocator())
    mem.mutex_allocator_init(packet_scratch, os.heap_allocator())
    // packet_scratch := new(mem.Scratch, os.heap_allocator())
    // mem.scratch_init(packet_scratch, PACKET_SCRATCH_BUFFER_SIZE, backup_allocator=os.heap_allocator())
    
    // NOTE: disallow out of band allocations larger than allocator cap, as they would be leaked either way
    // packet_scratch.backup_allocator = mem.panic_allocator()
    // packet_scratch.leaked_allocations.allocator = mem.panic_allocator()
    
    return ClientConnection {
        socket = socket,
        state  = .Handshake,
        
        // packet_scratch_alloc = mem.scratch_allocator(packet_scratch),
        packet_scratch_alloc = mem.mutex_allocator(packet_scratch),
        rx_buf = create_network_buf(160*mem.Megabyte, allocator=os.heap_allocator()),
        tx_buf = create_network_buf(160*mem.Megabyte, allocator=os.heap_allocator()),
    }
}

// Shuts down and unregisters a connection from all subsystems, and deallocates it.
@(private="file")
_finalize_client :: proc(state: ^NetworkWorkerState, client_conn: ClientConnection) {
    tracy.Zone()
    // ensure termination has been initiated and pending work is flushed, otherwise we would leak memory
    // and risk terminal packets not being sent.
    assert(_should_finalize_disconnect(client_conn))

    // FIXME: probably want to handle error
    reactor.unregister_client(state.io_ctx, client_conn.socket)
    spsc_enqueue(state.outbound_queue, TerminateClientRequest { client=client_conn.socket })
    
    _, client_conn := delete_key(&state.connections, client_conn.socket)
    destroy_network_buf(client_conn.tx_buf)
    destroy_network_buf(client_conn.rx_buf)
    
    scratch_alloc := cast(^mem.Mutex_Allocator) client_conn.packet_scratch_alloc.data
    // ensure right allocator is used to free buffer, instead of panic allocator
    // scratch_alloc := cast(^mem.Scratch) client_conn.packet_scratch_alloc.data
    // scratch_alloc.backup_allocator = os.heap_allocator()
    // mem.scratch_destroy(scratch_alloc)
    free(scratch_alloc, os.heap_allocator())
}
