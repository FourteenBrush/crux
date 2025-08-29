// A poll-based reactor implementation where interests in IO events are registered and polled.
// These IO events are bound to a certain client socket and indicate the state of their socket.
package reactor

import "core:net"

// Event emitted by polling the IOContext.
Event :: struct {
    // The client socket that emitted the event
    client: net.TCP_Socket,
    // Multiple flags might be present at the same time, as to batch multiple events
    flags: EventFlags,
}

EventFlags :: bit_set[EventFlag]

EventFlag :: enum {
    Readable,
    Writable,
    Err,
    // Read hangup or abrupt disconnection
    Hangup,
}

IOContext :: _IOContext

create_io_context :: proc() -> (IOContext, bool) {
    return _create_io_context()
}

destroy_io_context :: proc(ctx: ^IOContext) {
    _destroy_io_context(ctx)
}

register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    return _register_client(ctx, client)
}

unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    return _unregister_client(ctx, client)
}

// Inputs:
// - `timeout_ms`: the waiting timeout in ms, -1 waits indefinitely, 0 means return immediately
await_io_events :: proc(ctx: ^IOContext, events_out: ^[$N]Event, timeout_ms: int) -> (n: int, ok: bool) {
    return _await_io_events(ctx, events_out, timeout_ms)
}