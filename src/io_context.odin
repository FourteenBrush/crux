#+build linux
package crux

import "core:net"
import "core:sys/linux"

IOContext :: struct {
    epoll_fd: linux.Fd,
}

// Event emitted by polling the IOContext.
// TODO: move to shared stub when we create a package for this
Event :: struct {
    // Thc client socket that emitted the event
    client: net.TCP_Socket,
    // Multiple flags might be present at the same time, as to batch multiple events
    flags: EventFlags,
}

EventFlags :: bit_set[EventFlag]

EventFlag :: enum {
    In,
    Out,
    Err,
    Hup,
}

create_io_context :: proc() -> (ctx: IOContext, ok: bool) {
    epoll_fd, errno := linux.epoll_create()
    if errno != .NONE do return
    return IOContext { epoll_fd = epoll_fd }, true
}

destroy_io_context :: proc(ctx: ^IOContext) {
    linux.close(ctx.epoll_fd)
}

register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    event := linux.EPoll_Event {
        events = .IN,
        data = { fd = linux.Fd(client) },
    }
    errno := linux.epoll_ctl(ctx.epoll_fd, .ADD, linux.Fd(client), &event)
    return errno == .NONE
}

unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    errno := linux.epoll_ctl(ctx.epoll_fd, .DEL, linux.Fd(client), nil)
    return errno == .NONE
}

// Params:
// - events_out: a buffer that is at least EPOLL_EVENT_BUF_SIZE long
await_io_events :: proc(ctx: ^IOContext, events_out: ^[$N]Event, timeout: int) -> (n: int, ok: bool) {
    epoll_events: [N]linux.EPoll_Event

    nready, errno := linux.epoll_wait(ctx.epoll_fd, &epoll_events[0], len(epoll_events), timeout=i32(timeout))
    if errno != .NONE do return

    for event, i in epoll_events[:nready] {
        flags: EventFlags
        if event.events & .IN == .IN {
            flags += {.In}
        }
        if event.events & .OUT == .OUT {
            flags += {.Out}
        }
        if event.events & .ERR == .ERR {
            flags += {.Err}
        }
        // handle abrupt disconnection and read hangup the same way
        if event.events & .HUP == .HUP || event.events & .RDHUP == .RDHUP {
            flags += {.Hup}
        }

        // map to our even type
        events_out[i] = Event {
            client = net.TCP_Socket(event.data.fd),
            flags = flags,
        }
    }
    return int(nready), true
}
