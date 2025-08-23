// A poll-based reactor implementation where interests in IO events are registered and polled.
// These IO events are bound to a certain client socket and indicate the state of their socket.
package reactor

import "core:net"

// - we can only associate 64 bits of user data with epoll/iocp events
// - instead of storing the socket, which is used as key with a mutex -> ClientConnection,
// we want to have a direct pointer (as the client connections mutex only guards modifications on the map, not on the connections),
// a ptr is not stable, perhaps use a slotmap index, also not a pointer..
// 
// TODO: using spinlock was the first idea, as the critical section is small (map_insert/map_get call),
// but only allowing one thread in at a time might stall when having a lot of clients?
// semaphore style spinlock?

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
