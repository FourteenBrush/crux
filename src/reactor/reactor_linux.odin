package reactor

import "core:sys/posix"
@(require) import "core:log"
@(require) import "core:net"
@(require) import "core:mem"
@(require) import "base:runtime"
@(require) import "core:sys/linux"
@(require) import "core:container/queue"

@(require) import "lib:tracy"

when !USE_IO_URING {
    
// From epoll_wait
@(private)
_TIMEOUT_INFINITE :: -1

@(private)
_IOContext :: struct {
    epoll_fd: linux.Fd,
    wakeup_eventfd: linux.Fd,
    server_sock: net.TCP_Socket,
    // Allocator used to allocate recv buffers, the pending writes map and slices of iovecs.
    allocator: mem.Allocator,
    
    // Per socket queue of pending outbound writes, each entry inside the write queue represents a buffer
    // previously submitted via `submit_write_copy`. Buffers remain owned by the caller until a corresponding
    // `.Write` or `.Error` completion is emitted for every one of them.
    pending_writes: map[net.TCP_Socket]WriteQueue,
    // Maximum number of iovecs to be sent at once over the network. If bigger vectorized writes occur,
    // they will be buffered.
    sysconf_iov_max: int,
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
    iov_idx: int,
    // offset inside current iovec
    iov_off: int,
    // Whether we have enabled EPOLLOUT notifications for this client (not enabled for new clients).
    // This is set to false and an epoll_ctl(.., MOD, events - {EPOLLOUT}) is executed whenever the write queue
    // is fully drained, this to avoid unnecessary thread wakeups for data that isn't there.
    // The opposite is done whenever a write is submitted.
    epollout_armed: bool,
}

// NOTE: .HUP and .ERR are implicit for epoll_wait
@(private="file")
EPOLL_EVENTS_NO_OUT :: linux.EPoll_Event_Set { .IN, .RDHUP }

@(private="file")
EPOLL_EVENTS_OUT_ARMED :: EPOLL_EVENTS_NO_OUT | { .OUT }

@(private)
_create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: IOContext, ok: bool) {
    epoll_fd, errno := linux.epoll_create()
    if errno != .NONE do return
    defer if !ok do linux.close(epoll_fd)
    
    ctx.wakeup_eventfd, errno = linux.eventfd(0, {.NONBLOCK})
    if errno != .NONE do return
    defer if !ok do linux.close(ctx.wakeup_eventfd)
    
    ctx.epoll_fd = epoll_fd
    ctx.server_sock = server_sock
    // TODO: convert to pool based thing, together with reactor_windows
    ctx.allocator = _make_instrumented_alloc(runtime.heap_allocator(), meta_allocator=runtime.heap_allocator())
    ctx.pending_writes = make(map[net.TCP_Socket]WriteQueue, ctx.allocator)

    ctx.sysconf_iov_max = int(posix.sysconf(._IOV_MAX))
    assert(ctx.sysconf_iov_max > 0, "error retrieving _IOV_MAX")
    
    // register server sock to detect inbound connections
    _register_client(&ctx, ctx.server_sock) or_return
    // add wakeup eventfd
    _register_client(&ctx, net.TCP_Socket(ctx.wakeup_eventfd)) or_return
    
    return ctx, true
}

@(private)
_close_accept_loop :: proc(ctx: ^IOContext) {
    errno := linux.epoll_ctl(ctx.epoll_fd, .DEL, linux.Fd(ctx.server_sock), nil)
    assert(errno == .NONE, "failed to unregister server sock")
}

@(private)
_destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    // NOTE: only holds the clients that have already performed writes, so not 100% correct
    assert(len(ctx.pending_writes) == 0, "clients must be unregistered")
    
    linux.close(ctx.epoll_fd)
    linux.close(ctx.wakeup_eventfd)
    delete(ctx.pending_writes)
    queue.destroy(&ctx.completion_queue) // no-op if zero initialized
    _destroy_instrumented_alloc(ctx.allocator, meta_allocator=runtime.heap_allocator())
}

// NOTE: also used by server socket
@(private="file")
_register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    tracy.Zone()

    event := _epoll_event(ctx, client, EPOLL_EVENTS_NO_OUT)
    errno := linux.epoll_ctl(ctx.epoll_fd, .ADD, linux.Fd(client), &event)
    return errno == .NONE
}

@(private)
_disable_read_interest :: proc(ctx: ^IOContext, conn: net.TCP_Socket) -> bool {
    // preserve existing EPOLLOUT bit to not block writes
    events := EPOLL_EVENTS_NO_OUT
    if wq := &ctx.pending_writes[conn]; wq != nil && wq.epollout_armed {
        events = EPOLL_EVENTS_OUT_ARMED
    }

    ev := _epoll_event(ctx, conn, events & ~{.IN})
    // returns ENOENT on unregistered fds
    return linux.epoll_ctl(ctx.epoll_fd, .MOD, linux.Fd(conn), &ev) != .NONE
}

@(private)
_unregister_client :: proc(ctx: ^IOContext, conn: net.TCP_Socket) -> bool {
    tracy.Zone()

    ok := linux.epoll_ctl(ctx.epoll_fd, .DEL, linux.Fd(conn), nil) == .NONE
    
    _, pending_writes := delete_key(&ctx.pending_writes, conn)
    // emit completions for all aborted/partial writes
    for stale_write in pending_writes.iovecs[pending_writes.iov_idx:] {
        comp := Completion {
            socket = conn,
            operation = .Error,
            buf = stale_write.base[:stale_write.len],
        }
        // TODO: replace with _emit_completion() here, but we do not have access to its required params
        queue.append(&ctx.completion_queue, comp)
    }
    
    delete(pending_writes.iovecs)
    net.close(conn)
    return ok
}

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
    epoll_nready: i32
    errno: linux.Errno
    for {
        tracy.ZoneN("epoll_wait")
        // NOTE: timer resolution is already fine with CLOCK_MONOTONIC
        epoll_nready, errno = linux.epoll_wait(ctx.epoll_fd, &events[0], i32(len(events)), i32(timeout_ms))
        if errno != .EINTR do break
    }
    if errno != .NONE do return 0, false

    for event in events[:epoll_nready] {
        tracy.ZoneN("event io")
        socket := net.TCP_Socket(event.data.fd)
        emitted_hangup := false

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
            if linux.Fd(socket) == ctx.wakeup_eventfd {
                // reset wakeup counter back to 0, wakes up epoll when > 0
                buf: [8]u8
                _, errno = linux.read(ctx.wakeup_eventfd, buf[:])
                assert(errno == .NONE, "read() from eventfd should not fail")
                continue
            }
            
            comp := socket == ctx.server_sock \
                ? _do_accept(ctx) or_continue \
                : _do_read(ctx, socket) or_continue
                
            _emit_completion(ctx, completions_out, &nproduced, comp)
            emitted_hangup = comp.operation == .PeerHangup
        }
        if .OUT in event.events {
            assert(linux.Fd(socket) != ctx.wakeup_eventfd)
            _do_write(ctx, socket, completions_out, &nproduced)
        }
        if !emitted_hangup && (.HUP in event.events || .RDHUP in event.events) {
            // handle abrupt disconnection and read hangup the same way
            _emit_completion(ctx, completions_out, &nproduced, Completion { socket = socket, operation = .PeerHangup })
        }
    }
    return nproduced, true
}

@(private="file", require_results)
_do_accept :: proc(ctx: ^IOContext) -> (comp: Completion, emit: bool) {
    client_sock, endpoint, accept_err := net.accept_tcp(ctx.server_sock, /*client options*/{ no_delay=true })
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
    comp.endpoint = endpoint
    return comp, true
}

@(private="file", require_results)
_do_read :: proc(ctx: ^IOContext, socket: net.TCP_Socket) -> (comp: Completion, emit: bool) {
    recv_buf := mem.alloc_bytes_non_zeroed(RECV_BUF_SIZE, align_of(u8), ctx.allocator) or_else panic("OOM")
    nread, recv_err := linux.recv(linux.Fd(socket), recv_buf, {.NOSIGNAL})
    if recv_err == .EAGAIN || recv_err == .EWOULDBLOCK {
        delete(recv_buf, ctx.allocator)
        return comp, false
    }
    
    comp.socket = socket
    comp.operation = .Read
    switch {
    case recv_err != .NONE:
        _log_error(recv_err, "recv() failed")
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
    assert(wq.iov_idx < len(wq.iovecs), "full drain did not reset write queue")
    
    // apply iovec head_off by mutating first one in iovec slice, then restore it after syscall
    orig_vec: Maybe(linux.IO_Vec) = nil
    if wq.iov_off > 0 {
        vec := &wq.iovecs[wq.iov_idx]
        orig_vec = vec^
        vec.base = vec.base[wq.iov_off:]
        vec.len -= uint(wq.iov_off)
    }
    
    transmission_cap := min(len(wq.iovecs) - wq.iov_idx, ctx.sysconf_iov_max)
    msg := linux.Msg_Hdr { iov = wq.iovecs[wq.iov_idx:][:transmission_cap] }
    nwritten, send_err := linux.sendmsg(linux.Fd(socket), &msg, {.NOSIGNAL})
    
    if orig_vec, ok := orig_vec.?; ok {
        // restore mutated iovec so caller receives correct completion bufs
        wq.iovecs[wq.iov_idx] = orig_vec
    }

    if send_err == .EAGAIN || send_err == .EWOULDBLOCK {
        return
    }
    if send_err != .NONE {
        _log_error(send_err, "sendmsg() failed")
        // pass allocated buffers back to caller
        for vec in wq.iovecs[wq.iov_idx:] {
            comp := Completion {
                socket = socket,
                operation = .Error,
                buf = vec.base[:vec.len],
            }
            _emit_completion(ctx, completions_out, idx_ptr, comp)
        }
        // drop buffers to not resume on next EPOLLOUT
        _reset_write_queue(wq)
        _ = _arm_epollout(ctx, wq, socket, .Disarm)
        return
    }
    
    fully_drained := _advance_write_queue(ctx, wq, socket, nwritten, completions_out, idx_ptr)
    if fully_drained {
        _ = _arm_epollout(ctx, wq, socket, .Disarm)
    }
}

// Depending on `nwritten`, which is the result of a write call for the given write queue.
// - Emits completions for every written iovec inside the queue
// - Advances offsets to handle partial writes
@(private="file", require_results)
_advance_write_queue :: proc(
    ctx: ^IOContext,
    wq: ^WriteQueue,
    socket: net.TCP_Socket,
    nwritten: int,
    // params from _emit_completion()
    completions_out: []Completion,
    idx_ptr: ^int,
) -> (fully_drained: bool) {
    // for partial writes: advance cursor and resume sending on the next EPOLLOUT.
    // every iovec corresponds to a write operation so send completions for all fully written ones

    remaining := nwritten // nr of bytes we should consider to either emit a completion for or handle a partial write
    for remaining > 0 && wq.iov_idx < len(wq.iovecs) {
        #no_bounds_check vec := &wq.iovecs[wq.iov_idx]
        // how many bytes left in this iovec
        available := int(vec.len) - wq.iov_off
        
        if remaining < available {
            // iovec, which happened to be partially written
            wq.iov_off += remaining
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
        wq.iov_idx += 1
        wq.iov_off = 0
    }
    
    // queue fully drained
    if wq.iov_idx >= len(wq.iovecs) {
        _reset_write_queue(wq)
        return true
    }
    return false
}

@(private="file")
_reset_write_queue :: proc(wq: ^WriteQueue) {
    resize(&wq.iovecs, 0)
    wq.iov_idx = 0
    wq.iov_off = 0
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
_submit_write :: proc(ctx: ^IOContext, conn: net.TCP_Socket, data: []u8) -> bool {
    _, write_queue, zeroed_insert, _ := map_entry(&ctx.pending_writes, conn)
    if zeroed_insert {
        write_queue.iovecs.allocator = ctx.allocator
    }
    
    if !write_queue.epollout_armed {
        _arm_epollout(ctx, write_queue, conn, .Arm) or_return
    }
    
    append(&write_queue.iovecs, linux.IO_Vec { raw_data(data), len(data) })
    return true
}

@(private)
_wakeup :: proc(ctx: ^IOContext) {
    // add one to counter, a value > 0 causes epoll to wake up with an EPOLLIN for this fd
    one := u64(1) // needs an 8 bytes buffer or EINVAL is returned
    _, errno := linux.write(ctx.wakeup_eventfd, mem.ptr_to_bytes(&one))
    assert(errno == .NONE)
}

@(private="file", require_results)
_arm_epollout :: proc(ctx: ^IOContext, wq: ^WriteQueue, socket: net.TCP_Socket, mode: enum { Arm, Disarm }) -> bool {
    event := _epoll_event(ctx, socket, mode == .Arm ? EPOLL_EVENTS_OUT_ARMED : EPOLL_EVENTS_NO_OUT)
    errno := linux.epoll_ctl(ctx.epoll_fd, .MOD, linux.Fd(socket), &event)
    if errno != .NONE do return false
    
    wq.epollout_armed = mode == .Arm
    return true
}

@(private="file")
_epoll_event :: proc(ctx: ^IOContext, socket: net.TCP_Socket, events: linux.EPoll_Event_Set) -> (ev: linux.EPoll_Event) {
    ev.events = events
    ev.data.fd = linux.Fd(socket)
    return
}

@(private="file")
_log_error :: proc(#any_int err: u32, message: string) {
    log.logf(ERROR_LOG_LEVEL, "%s: %s", message, linux.Errno(err))
}

}
