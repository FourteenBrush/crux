// A poll-based reactor implementation which handles all IO operations on client connections.
// Upon polling, completions may be emitted for registered sockets, which indicate the outcome of IO operations that
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

// Completion emitted by polling the IOContext, indicating the outcome of an IO operation.
Completion :: struct {
    // The buffer where received data is stored in, only applicable to a read operations.
    // The number of bytes affected in the io operation, only used for read and write operations.
    recv_buf: []u8 `fmt:"-"`,
    // The affected socket, this is always the socket that emitted the completion, except
    // for cases where the server socket accepts new clients, then this stores the newly accepted client
    // and `Operation.NewConnection` is set in `operations`.
    // Always configured to be non-blocking.
    socket: net.TCP_Socket,
    // The number of bytes affected for the read or write operation as a whole.
    nr_of_bytes_affected: u32, // assuming no more than ~4GiB
    operation: Operation,
}

Operation :: enum u8 {
    // An error occured during the execution or the processing of the IO operation.
    // The downstream may probably want to check this first before checking other completions.
    // Additional error information might be logged on the `context.logger` on the call to `await_io_completions`,
    // with a log level of `ERROR_LOG_LEVEL`.
    Error,
    // Data was read from the client socket and is now available in the `Completion.recv_buf`.
    // This always indicates a successful read, an EOF condition is handled with `.PeerHangup` instead.
    Read,
    Write,
    // Read hangup or abrupt disconnection.
    // The associated socket in the completion cannot be used for IO anymore.
    PeerHangup,
    // Represents a newly accepted client socket, stored in `Completion.socket`. The socket is configured
    // to be non-blocking and is already registered in this subsystem.
    // This merely acts as a way to notify the downstream, so they may update their internal data structures.
    NewConnection,
}

// Operation context, must not be moved after first use.
IOContext :: _IOContext

// Creates a new `IOContext`, which registers the server socket as a source to accept new incoming clients.
// Inputs:
// - `server_sock`: the non-blocking server socket that is already listening.
// Will use `context.logger` to log error messages.
//
// Any connections accepted from the server socket will be implicitly registered, upon registration
// `Operation.Read` completions may immediately be emitted whenever the client sends data. Write completions
// only occur after calling `submit_write_*` procedures.
create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (IOContext, bool) {
    return _create_io_context(server_sock, allocator)
}

// Destroys the given `IOContext`, the passed allocator must be the same as the one used in `create_io_context`.
// IMPORTANT NOTE: the caller must first call `unregister_client` on all registered clients, as those may store refcounted
// data that points to this IO context. This task is delegated to them as they probably have better means of
// keeping track of registered clients, whereas we do not want to pay for that overhead.
destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    _destroy_io_context(ctx, allocator)
}

// Unregisters a client from the IO context, after this call, the client will no longer produce new completions.
// Any pending IO operations will be canceled, buf completions that were already
// queued in the internal buffers before cancellation, may still be delivered.
// As a result, some completions might still be delived after unregistering, even though
// no new IO operations were issued. The application should safeguard against this behaviour.
unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    return _unregister_client(ctx, client)
}

// Await IO completions for any of the registered clients (excluding the server socket).
// This function returns when either `timeout_ms` has elapsed, or at least one completion has been awaited.
// Inputs:
// - `timeout_ms`: the waiting timeout in ms, 0 means return immediately if no completions can be awaited.
await_io_completions :: proc(ctx: ^IOContext, completions_out: []Completion, timeout_ms: int) -> (n: int, ok: bool) {
    return _await_io_completions(ctx, completions_out, timeout_ms)
}

submit_write_copy :: proc(ctx: ^IOContext, client: net.TCP_Socket, data: []u8) -> bool {
    return _submit_write_copy(ctx, client, data)
}