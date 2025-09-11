package reactor

import "core:net"
import "core:mem"
import "core:sys/linux"

@(private)
_IOContext :: struct {
    epoll_fd: linux.Fd,
}

@(private)
_create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: IOContext, ok: bool) {
    // TODO: does timer resolution need to be fixed here?
    epoll_fd, errno := linux.epoll_create()
    if errno != .NONE do return
    return IOContext { epoll_fd = epoll_fd }, true
}

@(private)
_destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    // FIXME: perhaps handle error
    linux.close(ctx.epoll_fd)
}

@(private)
_register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    event := linux.EPoll_Event {
        // NOTE: .HUP and .ERR are implicit
        events = {.IN, .OUT, .RDHUP},
        data = { fd = linux.Fd(client) },
    }
    errno := linux.epoll_ctl(ctx.epoll_fd, .ADD, linux.Fd(client), &event)
    return errno == .NONE
}

@(private)
_unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    errno := linux.epoll_ctl(ctx.epoll_fd, .DEL, linux.Fd(client), nil)
    return errno == .NONE
}

// TODO: timeout: 0 handle returned bool correctly
@(private)
_await_io_completions :: proc(ctx: ^IOContext, completions_out: []Completion, timeout_ms: int) -> (n: int, ok: bool) {
    events := make([]linux.EPoll_Event, len(completions_out), context.temp_allocator)

    nready, errno := linux.epoll_wait(ctx.epoll_fd, &events[0], 32(len(events)), timeout=i32(timeout_ms))
    if errno != .NONE do return

    #no_bounds_check comp := completions_out[i]
    comp.socket = net.TCP_Socket(event.data.fd)

    for event, i in events[:nready] {
        flags:
        if .IN in event.events {
            comp.operations += {.Read}
        }
        if .OUT in event.events {
            comp.operations += {.Write}
        }
        if .ERR in event.events {
            comp.operations += {.Error}
        }
        // handle abrupt disconnection and read hangup the same way
        if .HUP in event.events || .RDHUP in event.events {
            comp.operations += {.PeerHangup}
        }
    }
    return int(nready), true
}

@(private)
_submit_write_copy :: proc(ctx: ^IOContext, client: net.TCP_Socket, data: []u8) -> bool {
    // TODO: append iovec to userspace queue
    return false
}