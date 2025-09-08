// A poll-based reactor implementation where sockets are registered, in order to express interest in IO events.
// Upon polling, events may be emitted for registered sockets, which indicate the outcome of IO events that
// were started beforehand. The application code is given an opportunity to act on the result of those operations.
package reactor

import "core:net"
import "core:mem"
import "core:log"

@(private)
RECV_BUF_SIZE :: 2048

// The log level used for error logs produced by the `IOContext`, specified in this package
// to avoid circular import errors. Should be closely kept in sync with other custom log levels.
// This log level will be used in conjunction with `context.logger`.
ERROR_LOG_LEVEL :: log.Level(9)

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
    recv_buf: []u8 `fmt:"-"`,
    // The number of bytes affected in the io operation, only used for read and write operations.
    nr_of_bytes_affected: int,
}

EventOperation :: enum {
    // An error occured during the execution or the processing of the IO operation.
    // The downstream may probably want to check this first before checking other events.
    Error,
    // Data was read from the client socket and is now available in the `Event.recv_buf`.
    // This always indicates a successful read, an EOF condition is handled with `.Hangup` instead.
    Read,
    Write,
    // Read hangup or abrupt disconnection.
    // The associated socket in the event cannot be used for IO anymore.
    Hangup,
    // Represents a newly accepted client socket, stored in `Event.socket`. The socket is configured
    // to be non-blocking and is already registered in this subsystem.
    // This merely acts as a way to notify the downstream, so they may update their internal data structures.
    NewConnection,
}

IOContext :: _IOContext

// Creates a new `IOContext`, which registers the server socket as a source to accept new incoming clients.
// Inputs:
// - `server_sock`: the non-blocking server socket that is already listening.
// Will use `context.logger` to log error messages.
create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (IOContext, bool) {
    return _create_io_context(server_sock, allocator)
}

// Destroys the given `IOContext`, the passed allocator must be the same as the one used in `create_io_context`.
destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    _destroy_io_context(ctx, allocator)
}

// Registers a client to this subsystem, upon registration `EventOperation.Read` events may immediately
// be emitted whenever the client sends data. Write completions only occur after calling `submit_write_*` procedures.
register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    return _register_client(ctx, client)
}

// Unregisters a client from the IO context, after this call, the client will no longer produce new events.
// Any pending IO operations will be canceled, buf events that were already
// queued in the system's internal buffers before cancellation, may still be delivered.
// As a result, some events might still be delived after unregistering, even though
// no new IO operations were issued. The application should safeguard against this behaviour.
unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    return _unregister_client(ctx, client)
}

// Await IO events for any of the registered clients (excluding the server socket).
// This function returns when either `timeout_ms` has elapsed, or at least one event has been awaited.
// Inputs:
// - `timeout_ms`: the waiting timeout in ms, 0 means return immediately if no events can be awaited.
await_io_events :: proc(ctx: ^IOContext, events_out: []Event, timeout_ms: int) -> (n: int, ok: bool) {
    return _await_io_events(ctx, events_out, timeout_ms)
}

submit_write_copy :: proc(ctx: ^IOContext, client: net.TCP_Socket, data: []u8) -> bool {
    return _submit_write_copy(ctx, client, data)
}