package reactor

@(require) import "core:log"
@(require) import "core:net"
@(require) import "core:mem"
@(require) import "base:runtime"
@(require) import "core:sys/linux"
@(require) import "core:container/queue"

@(require) import "lib:tracy"

when !USE_IO_URING {

@(private)
_IOContext :: struct {
    epoll_fd: linux.Fd,
    server_sock: net.TCP_Socket,
    // Allocator used to allocate recv buffers, the pending writes map and slices of iovecs.
    allocator: mem.Allocator,
    
    // Per socket queue of pending outbound writes, each entry inside the write queue represents a buffer
    // previously submitted via `submit_write_copy`. Buffers remain owned by the caller until a corresponding
    // `.Write` or `.Error` completion is emitted for every one of them.
    pending_writes: map[net.TCP_Socket]WriteQueue,
    // Internal completion queue used when the `completions_out` buffer passed to `await_io_completions`
    // is saturated and we cannot reconstruct completion state from epoll alone.
    // Also handles epoll event batching as one EPoll_Event may occasionaly produce more than one completion.
    // NOTE: Lazily allocated.
    completion_queue: queue.Queue(Completion),
}

// Client socket specific write queue, to handle partial write state correctly.
@(private="file")
WriteQueue :: struct {
    iovecs: [dynamic]linux.IO_Vec,
    // which iovec we are on
    head_idx: int,
    // offset inside current iovec
    head_off: int,
}

@(private)
_create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: IOContext, ok: bool) {
    epoll_fd, errno := linux.epoll_create()
    if errno != .NONE do return
    
    ctx.epoll_fd = epoll_fd
    ctx.server_sock = server_sock
    // TODO: convert to pool based thing, together with reactor_windows
    ctx.allocator = _make_instrumented_alloc(runtime.heap_allocator(), meta_allocator=runtime.heap_allocator())
    ctx.pending_writes = make(map[net.TCP_Socket]WriteQueue, ctx.allocator)
    
    // register server sock to detect inbound connections
    _register_client(&ctx, ctx.server_sock) or_return
    
    return ctx, true
}

@(private)
_destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    assert(len(ctx.pending_writes) == 0, "clients must be unregistered")
    linux.close(ctx.epoll_fd)
    delete(ctx.pending_writes)
    _destroy_instrumented_alloc(ctx.allocator, meta_allocator=runtime.heap_allocator())
}

@(private="file")
_register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    tracy.Zone()

    event := linux.EPoll_Event {
        // NOTE: .HUP and .ERR are implicit
        events = {.IN, .OUT, .RDHUP},
        data = { fd = linux.Fd(client) },
    }
    errno := linux.epoll_ctl(ctx.epoll_fd, .ADD, linux.Fd(client), &event)
    return errno == .NONE
}

@(private)
_unregister_client :: proc(ctx: ^IOContext, conn: net.TCP_Socket) -> bool {
    tracy.Zone()

    ok := linux.epoll_ctl(ctx.epoll_fd, .DEL, linux.Fd(conn), nil) == .NONE
    _, pending_writes := delete_key(&ctx.pending_writes, conn)
    delete(pending_writes.iovecs)
    net.close(conn)
    return ok
}

// TODO: timeout: 0 handle returned bool correctly
@(private)
_await_io_completions :: proc(ctx: ^IOContext, completions_out: []Completion, timeout_ms: int) -> (n: int, ok: bool) {
    tracy.Zone()
    
    // drain internal queue first
    nproduced := 0
    for ; nproduced < len(completions_out); nproduced += 1 {
        comp := queue.pop_front_safe(&ctx.completion_queue) or_break
        #no_bounds_check completions_out[nproduced] = comp
    }
    // if user buffer is full, return early
    if nproduced == len(completions_out) {
        tracy.Message("reactor_epoll internal completion queue saturates user buffer")
        return nproduced, true
    }
    
    events := make([]linux.EPoll_Event, len(completions_out) - nproduced, context.temp_allocator)
    nready: i32
    errno: linux.Errno
    for {
        tracy.ZoneN("epoll_wait")
        // NOTE: timer resolution is already fine with CLOCK_MONOTONIC
        nready, errno = linux.epoll_wait(ctx.epoll_fd, &events[0], i32(len(events)), i32(timeout_ms))
        if errno != .EINTR do break
    }
    if errno != .NONE do return 0, false

    for event in events[:nready] {
        tracy.ZoneN("event io")
        socket := net.TCP_Socket(event.data.fd)

        // batch order processing: ERR -> IN -> OUT -> HUP/RDHUP
        if .ERR in event.events {
            _emit_completion(ctx, completions_out, &nproduced, Completion { socket = socket, operation = .Error })
            
            actual_err: linux.Errno
            _, opt_err := linux.getsockopt_base(linux.Fd(socket), int(linux.SOL_SOCKET), .ERROR, &actual_err)
            if opt_err == .NONE {
                _log_error(actual_err, "failed to poll client socket")
            }
            continue
        }
        
        if .IN in event.events {
            comp := socket == ctx.server_sock \
                ? _do_accept(ctx) or_continue \
                : _do_read(ctx, socket) or_continue
                
            _emit_completion(ctx, completions_out, &nproduced, comp)
        }
        if .OUT in event.events {
            _do_write(ctx, socket, completions_out, &nproduced)
        }
        if .HUP in event.events || .RDHUP in event.events {
            // handle abrupt disconnection and read hangup the same way
            // TODO: let the caller handle this, as they may receive a batched read and a hup, with a socket
            // that now ended up being closed...
            net.close(socket)
            _emit_completion(ctx, completions_out, &nproduced, Completion { socket = socket, operation = .PeerHangup })
        }
    }
    return int(nready), true
}

@(private="file", require_results)
_do_accept :: proc(ctx: ^IOContext) -> (comp: Completion, emit: bool) {
    client_sock, _, accept_err := net.accept_tcp(ctx.server_sock, /*client options*/{ no_delay=true })
    if accept_err != .None {
        log.warn("failed to accept client:", accept_err)
        return comp, false
    }
    defer if !emit {
        net.close(client_sock)
    }

    _ = net.set_blocking(client_sock, false)
    _register_client(ctx, client_sock) or_return
    comp.socket = client_sock
    comp.operation = .NewConnection
    return comp, true
}

@(private="file", require_results)
_do_read :: proc(ctx: ^IOContext, socket: net.TCP_Socket) -> (comp: Completion, emit: bool) {
    recv_buf := mem.alloc_bytes_non_zeroed(RECV_BUF_SIZE, align_of(u8), ctx.allocator) or_else panic("OOM")
    nread, recv_err := linux.recv(linux.Fd(socket), recv_buf, {.NOSIGNAL})
    if recv_err == .EAGAIN {
        delete(recv_buf, ctx.allocator)
        return comp, false
    }
    
    comp.socket = socket
    comp.operation = .Read
    switch {
    case recv_err != .NONE:
        comp.operation = .Error
        delete(recv_buf, ctx.allocator)
    case nread == 0:
        comp.operation = .PeerHangup
        delete(recv_buf, ctx.allocator)
    case:
        // successful read, recv buffer will be freed by caller
        comp.buf = recv_buf[:nread]
    }
    return comp, true
}

@(private="file")
_do_write :: proc(
    ctx: ^IOContext,
    socket: net.TCP_Socket,
    // params from _emit_completion()
    completions_out: []Completion,
    idx_ptr: ^int,
) {
    wq := &ctx.pending_writes[socket]
    if wq == nil || len(wq.iovecs) == 0 do return
    
    // apply iovec head_off by mutating first one in iovec slice, then restore it after syscall
    orig_vec: Maybe(linux.IO_Vec) = nil
    if wq.head_off > 0 {
        vec := &wq.iovecs[wq.head_idx]
        orig_vec = vec^
        vec.base = vec.base[wq.head_off:]
        vec.len -= uint(wq.head_off)
    }
    
    msg := linux.Msg_Hdr { iov = wq.iovecs[wq.head_idx:] }
    // FIXME: cap every sendmsg to sysconf(._IOV_MAX) (usually ~1024)
    nwritten, send_err := linux.sendmsg(linux.Fd(socket), &msg, {.NOSIGNAL})
    
    if orig_vec, ok := orig_vec.?; ok {
        // restore mutated iovec so caller receives correct completion bufs
        wq.iovecs[wq.head_idx] = orig_vec
    }

    if send_err != .NONE {
        // pass allocated buffers back to caller
        for vec in wq.iovecs {
            comp := Completion {
                socket = socket,
                operation = .Error,
                buf = vec.base[:vec.len],
            }
            _emit_completion(ctx, completions_out, idx_ptr, comp)
        }
        // drop buffers to not resume on next EPOLLOUT
        _reset_write_queue(wq)
        return
    }
    
    _advance_write_queue(ctx, wq, socket, nwritten, completions_out, idx_ptr)

    // TODO: remove EPOLLOUT on non partial write to not constantly receive EPOLLOUT notifications
    // when we have nothing to write
}

// Depending on `nwritten`, which is the result of a write call for the given write queue.
// - Emits completions for every written iovec inside the queue
// - Advances offsets to handle partial writes
@(private="file")
_advance_write_queue :: proc(
    ctx: ^IOContext,
    wq: ^WriteQueue,
    socket: net.TCP_Socket,
    nwritten: int,
    // params from _emit_completion()
    completions_out: []Completion,
    idx_ptr: ^int,
) {
    // for partial writes: advance cursor and resume sending on the next EPOLLOUT.
    // every iovec corresponds to a write operation so send completions for all fully written ones

    remaining := nwritten // nr of bytes we should consider to either emit a completion for or handle a partial write
    for remaining > 0 && wq.head_idx < len(wq.iovecs) {
        #no_bounds_check vec := &wq.iovecs[wq.head_idx]
        // how many bytes left in this iovec
        available := int(vec.len) - wq.head_off
        
        if remaining < available {
            // iovec, which happened to be partially written
            wq.head_off += remaining
            remaining = 0
            break
        }
        
        // fully consume iovec
        remaining -= available
        comp := Completion {
            socket = socket,
            operation = .Write,
            buf = vec.base[:vec.len],
        }
        _emit_completion(ctx, completions_out, idx_ptr, comp)
        wq.head_idx += 1
        wq.head_off = 0
    }
    
    // queue fully drained
    if wq.head_idx >= len(wq.iovecs) {
        _reset_write_queue(wq)
    }
}

@(private="file")
_reset_write_queue :: proc(wq: ^WriteQueue) {
    resize(&wq.iovecs, 0)
    wq.head_idx = 0
    wq.head_off = 0
}

// Either stores a completion directly to an output buffer if not saturated,
// otherwise queues it internally.
@(private="file")
_emit_completion :: proc(
    ctx: ^IOContext,
    completions_out: []Completion,
    idx_ptr: ^int,
    comp: Completion,
) {
    if idx_ptr^ < len(completions_out) {
        #no_bounds_check completions_out[idx_ptr^] = comp
        idx_ptr^ += 1
    } else {
        context.allocator = ctx.allocator // in case queue lazily initializes itself
        // TODO: make queue bounded
        queue.push_back(&ctx.completion_queue, comp)
    }
}

@(private)
_release_recv_buf :: proc(ctx: ^IOContext, buf: []u8) {
    delete(buf, ctx.allocator)
}

@(private)
_submit_write_copy :: proc(ctx: ^IOContext, conn: net.TCP_Socket, data: []u8) -> bool {
    // TODO: rearm epoll_ctl with EPOLL_CTL_MOD to achieve EPOLLOUT notifications
    _, write_queue, zeroed_insert, _ := map_entry(&ctx.pending_writes, conn)
    if zeroed_insert {
        write_queue.iovecs.allocator = ctx.allocator
    }
    
    append(&write_queue.iovecs, linux.IO_Vec { raw_data(data), len(data) })
    return true
}

@(private="file")
_log_error :: proc(#any_int err: u32, message: string) {
    log.logf(ERROR_LOG_LEVEL, "%s: %s", message, linux.Errno(err))
}

}
