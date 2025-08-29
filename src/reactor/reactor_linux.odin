package reactor

import "core:net"
import "core:sys/linux"

_IOContext :: struct {
    epoll_fd: linux.Fd,
}

_create_io_context :: proc() -> (ctx: IOContext, ok: bool) {
    epoll_fd, errno := linux.epoll_create()
    if errno != .NONE do return
    return IOContext { epoll_fd = epoll_fd }, true
}

_destroy_io_context :: proc(ctx: ^IOContext) {
    // FIXME: perhaps handle error
    linux.close(ctx.epoll_fd)
}

_register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    event := linux.EPoll_Event {
        // NOTE: .HUP and .ERR are implicit
        events = {.IN, .OUT, .RDHUP},
        data = { fd = linux.Fd(client) },
    }
    errno := linux.epoll_ctl(ctx.epoll_fd, .ADD, linux.Fd(client), &event)
    return errno == .NONE
}

_unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    errno := linux.epoll_ctl(ctx.epoll_fd, .DEL, linux.Fd(client), nil)
    return errno == .NONE
}

// TODO: pass slice instead of ptr to array
// TODO: timeout: 0 handle returned bool correctly
_await_io_events :: proc(ctx: ^IOContext, events_out: ^[$N]Event, timeout_ms: int) -> (n: int, ok: bool) {
    epoll_events: [N]linux.EPoll_Event

    nready, errno := linux.epoll_wait(ctx.epoll_fd, &epoll_events[0], len(epoll_events), timeout=i32(timeout_ms))
    if errno != .NONE do return

    for event, i in epoll_events[:nready] {
        flags: EventFlags
        if .IN in event.events {
            flags += {.Readable}
        }
        if .OUT in event.events {
            flags += {.Writable}
        }
        if .ERR in event.events {
            flags += {.Err}
        }
        // handle abrupt disconnection and read hangup the same way
        if .HUP in event.events || .RDHUP in event.events {
            flags += {.Hangup}
        }

        events_out[i] = Event {
            client = net.TCP_Socket(event.data.fd),
            flags = flags,
        }
    }
    return int(nready), true
}
