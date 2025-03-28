#+build linux
package reactor

import "core:net"
import "core:sys/linux"

IOContext :: struct {
    epoll_fd: linux.Fd,
}

create_io_context :: proc() -> (ctx: IOContext, ok: bool) {
    epoll_fd, errno := linux.epoll_create()
    if errno != .NONE do return
    return IOContext { epoll_fd = epoll_fd }, true
}

destroy_io_context :: proc(ctx: ^IOContext) {
    // FIXME: perhaps handle error
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

await_io_events :: proc(ctx: ^IOContext, events_out: ^[$N]Event, timeout: int) -> (n: int, ok: bool) {
    epoll_events: [N]linux.EPoll_Event

    nready, errno := linux.epoll_wait(ctx.epoll_fd, &epoll_events[0], len(epoll_events), timeout=i32(timeout))
    if errno != .NONE do return

    for event, i in epoll_events[:nready] {
        flags: EventFlags
        if event.events & .IN == .IN {
            flags += {.Readable}
        }
        if event.events & .OUT == .OUT {
            flags += {.Writable}
        }
        if event.events & .ERR == .ERR {
            flags += {.Err}
        }
        // handle abrupt disconnection and read hangup the same way
        if event.events & .HUP == .HUP || event.events & .RDHUP == .RDHUP {
            flags += {.Hangup}
        }

        // map to our even type
        events_out[i] = Event {
            client = net.TCP_Socket(event.data.fd),
            flags = flags,
        }
    }
    return int(nready), true
}
