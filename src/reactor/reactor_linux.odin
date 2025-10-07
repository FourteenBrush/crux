package reactor

import "core:log"
import "core:net"
import "core:mem"
import "base:runtime"
import "core:sys/linux"

import "lib:tracy"

@(private)
_IOContext :: struct {
    epoll_fd: linux.Fd,
    server_sock: net.TCP_Socket,
    allocator: mem.Allocator,
    
    // Yet to be sent writes per client.
    // TODO: probably [dynamic][]u8
    pending_writes: map[net.TCP_Socket][dynamic]linux.IO_Vec,
}

@(private)
_create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: IOContext, ok: bool) {
    // TODO: does timer resolution need to be fixed here?
    epoll_fd, errno := linux.epoll_create()
    if errno != .NONE do return
    
    ctx.epoll_fd = epoll_fd
    ctx.server_sock = server_sock
    ctx.allocator = runtime.heap_allocator() // TODO: convert to pool based thing, together with reactor_windows
    ctx.pending_writes = make(map[net.TCP_Socket][dynamic]linux.IO_Vec, ctx.allocator)
    
    // register server sock to detect inbound connections
    _register_client(&ctx, ctx.server_sock) or_return
    
    return ctx, true
}

@(private)
_destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    linux.close(ctx.epoll_fd)
    delete(ctx.pending_writes)
}

@(private="file")
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
_unregister_client :: proc(ctx: ^IOContext, handle: ConnectionHandle) -> bool {
    ok := linux.epoll_ctl(ctx.epoll_fd, .DEL, linux.Fd(handle.socket), nil) == .NONE
    _, pending_writes := delete_key(&ctx.pending_writes, handle.socket)
    delete(pending_writes)
    // TODO: IO cancelation and such
    net.close(handle.socket)
    return ok
}

// TODO: timeout: 0 handle returned bool correctly
@(private)
_await_io_completions :: proc(ctx: ^IOContext, completions_out: []Completion, timeout_ms: int) -> (n: int, ok: bool) {
    tracy.Zone()
    events := make([]linux.EPoll_Event, len(completions_out), context.temp_allocator)
    
    nready: i32
    errno: linux.Errno
    for {
        tracy.ZoneN("epoll_wait")
        nready, errno = linux.epoll_wait(ctx.epoll_fd, &events[0], i32(len(events)), i32(timeout_ms))
        if errno != .EINTR do break
    }
    if errno != .NONE do return

    i := 0
    for event in events[:nready] {
        discard_entry := false
        defer if discard_entry {
            nready -= 1
        } else {
            i += 1
        }
        
        #no_bounds_check comp := &completions_out[i]
        comp.socket = net.TCP_Socket(event.data.fd)

        // TODO: how do we handle epoll event batching?
        if .ERR in event.events {
            comp.operation = .Error
            
            actual_err: linux.Errno
            _, opt_err := linux.getsockopt_base(linux.Fd(comp.socket), int(linux.SOL_SOCKET), .ERROR, &actual_err)
            if opt_err == .NONE {
                _log_error(actual_err, "failed to poll socket")
            }
        } else if .IN in event.events {
            // accept client
            if comp.socket == ctx.server_sock {
                client_sock, _, accept_err := net.accept_tcp(ctx.server_sock, /*client options*/{ no_delay=true })
                if accept_err != .None {
                    discard_entry = true
                    log.warn("failed to accept client")
                    continue
                }
                // configure client socket
                if net.set_blocking(client_sock, false) != .None {
                    net.close(client_sock)
                    discard_entry = true
                    continue
                }
                discard_entry = true
                _register_client(ctx, client_sock) or_return
                discard_entry = false
                comp.operation = .NewConnection
                comp.socket = client_sock
                continue
            }
            
            comp.operation = .Read
            recv_buf := make([]u8, RECV_BUF_SIZE, ctx.allocator) or_else panic("OOM")
            n, recv_err := net.recv_tcp(comp.socket, recv_buf)
            switch {
            case n == 0:
                delete(recv_buf, ctx.allocator)
                comp.operation = .PeerHangup
                _ = _unregister_client(ctx, ConnectionHandle { socket=comp.socket })
            case recv_err == net.TCP_Recv_Error.Would_Block: // uh sure?
                delete(recv_buf, ctx.allocator)
                discard_entry = true
            case:
                // successful read
                comp.buf = recv_buf[:n]
            }
        } else if .OUT in event.events {
            pending_writes := &ctx.pending_writes[comp.socket]
            if pending_writes == nil || len(pending_writes) == 0 {
                discard_entry = true
                continue
            }
            
            comp.operation = .Write
            // TODO: returning only first buf for now
            comp.buf = mem.ptr_to_bytes(cast(^u8)pending_writes[0].base, cast(int)pending_writes[0].len)
            n, write_err := linux.writev(linux.Fd(comp.socket), pending_writes[:])
            assert(n > 0 && write_err == .NONE, "TODO: error handling")
            resize(pending_writes, 0)
        } else if .HUP in event.events || .RDHUP in event.events {
            // handle abrupt disconnection and read hangup the same way
            comp.operation = .PeerHangup
            net.close(comp.socket)
        }
    }
    return int(nready), true
}

@(private)
_release_recv_buf :: proc(ctx: ^IOContext, comp: Completion) {
    delete(comp.buf, ctx.allocator)
}

@(private)
_submit_write_copy :: proc(ctx: ^IOContext, handle: ConnectionHandle, data: []u8) -> bool {
    context.allocator = ctx.allocator
    _, pending_writes, _ := map_upsert(&ctx.pending_writes, handle.socket, [dynamic]linux.IO_Vec{})
    append(pending_writes, linux.IO_Vec { raw_data(data), len(data) })
    // TODO: assert <= sysconf(._IOV_MAX)
    return true
}

@(private="file")
_log_error :: proc(#any_int err: u32, message: string) {
    log.logf(ERROR_LOG_LEVEL, "%s: %s", message, linux.Errno(err))
}
