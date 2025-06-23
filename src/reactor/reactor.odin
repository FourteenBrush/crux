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
