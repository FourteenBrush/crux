// A poll-based reactor implementation where interests in IO events are registered and polled.
// These IO events are bound to a certain client socket and indicate the state of that socket.
package reactor

import "core:net"
import "core:mem"

@(private)
RECV_BUF_SIZE :: 2048

// Event emitted by polling the IOContext.
Event :: struct {
    // The affected socket, this is always the socket that emitted the event, except
    // for cases where the server socket accepts new clients, then this stores the newly accepted client.
    // Always configured to be non-blocking.
    socket: net.TCP_Socket,
    // Multiple flags might be present at the same time, as to batch multiple events.
    // Every flag set, accounts for one batched event.
    operations: bit_set[EventOperation],

    // The buffer where received data is stored in, only applicable to a read operations.
    recv_buf: []u8,
    // The number of bytes affected in the io operation, only used for read and write operations.
    nr_of_bytes_affected: int,
}

EventOperation :: enum {
    // An error occured on the execution of the IO operation.
    // The downstream may probably want to check this first over other events.
    Error,
    // Data was read from the client socket and is now available in the `Event`.
    // This always indicates a successful read, an EOF condition is handled with `.Hangup` instead.
    Read,
    Write,
    // Read hangup or abrupt disconnection
    Hangup,
    // This `Event` represents a newly accepted client socket, available in `Event.socket`.
    // The socket is already registered in this subsystem.
    // This merely acts as a way to notify the downstream, so they may update their internal data structures.
    NewClient,
}

IOContext :: _IOContext

create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (IOContext, bool) {
    return _create_io_context(server_sock, allocator)
}

destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    _destroy_io_context(ctx, allocator)
}

register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    return _register_client(ctx, client)
}

unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    return _unregister_client(ctx, client)
}

// Await IO events for any of the registered clients (excluding the server socket).
// Inputs:
// - `timeout_ms`: the waiting timeout in ms, -1 waits indefinitely, 0 means return immediately
// TODO: handle this timeout correctly for different platforms
await_io_events :: proc(ctx: ^IOContext, events_out: []Event, timeout_ms: int) -> (n: int, ok: bool) {
    return _await_io_events(ctx, events_out, timeout_ms)
}

submit_write_copy :: proc(ctx: ^IOContext, client: net.TCP_Socket, data: []u8) -> bool {
    return _submit_write_copy(ctx, client, data)
}