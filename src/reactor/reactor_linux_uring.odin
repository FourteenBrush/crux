#+build linux
#+vet explicit-allocators
package reactor

@(require) import "core:os"
@(require) import "core:log"
@(require) import "core:net"
@(require) import "core:mem"
@(require) import "core:sys/linux"
@(require) import "core:sys/linux/uring"
@(require) import "core:container/queue"

@(require) import "base:intrinsics"

@(require) import "lib:tracy"

// TODO: VV
when true {

    @(private)
    _TIMEOUT_INFINITE :: -1

    @(private="file")
    CTRL_OOM :: "OOM while allocating io control block"

    // NOTE: must be kept relatively low due to mem limits (max locked pages, etc..), effectively
    // causing a memlock() to fail
    // TODO: document /etc/security/limits.conf fix
    @(private="file")
    SQ_INIT_ENTRIES :: 128
    #assert(SQ_INIT_ENTRIES & (SQ_INIT_ENTRIES - 1) == 0)
    #assert(SQ_INIT_ENTRIES < uring.MAX_ENTRIES)

    @(private="file")
    WAKEUP_USER_DATA :: u64(0xdeadbeef)

    @(private)
    PlatformIOContext :: struct {
        server_sock: linux.Fd,
        allocator: mem.Allocator,
        
        ring: uring.Ring,
        accept_loop_closed: bool,
        // If kernel submission queue is full, operations are enqueued here and retried on the next `await_io_completions`.
        unqueued: queue.Queue(UnqueuedOperation),
    }

    @(private="file")
    UnqueuedOperation :: struct {
        op: ^IOOperation,
        fd: linux.Fd,
    }

    @(private)
    _create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: PlatformIOContext, ok: bool) {
        ctx.server_sock = linux.Fd(server_sock)
        ctx.allocator = allocator
        
        params := uring.DEFAULT_PARAMS
        errno := uring.init(&ctx.ring, &params, entries=SQ_INIT_ENTRIES)
        defer if errno != .NONE {
            _log_error(errno, "failed to init io uring")
        }
        if errno != .NONE do return

        // limit nr of spawned kernel worker threads, unbounded count is most important to us, as this refers to socket io and is very high by default
        // reference: https://man7.org/linux/man-pages/man3/io_uring_register_iowq_max_workers.3.html
        curr_max_workers: [2]u32 // default bounded count = min(sq_size, 4*ncpus)
        linux.io_uring_register(ctx.ring.fd, .REGISTER_IOWQ_MAX_WORKERS, &curr_max_workers, len(curr_max_workers))
        max_workers := [2]u32 {
            /*bounded=*/ cast(u32) min(SQ_INIT_ENTRIES, 4 * os.get_processor_core_count()),
            /*unbounded*/64,
        }
        log.debugf("uring max workers current: (bounded=%d, unbounded=%d), setting to (%d, %d)", expand_values(curr_max_workers), expand_values(max_workers))
        errno = linux.io_uring_register(ctx.ring.fd, .REGISTER_IOWQ_MAX_WORKERS, &max_workers, len(max_workers))
        if errno != .NONE {
            _log_error(errno, "failed to configure uring wq max workers")
        }

        ctx.unqueued.data.allocator = ctx.allocator

        _initiate_accept(&ctx)
        
        return ctx, true
    }
    
    @(private)
    _destroy_io_context :: proc(ctx: ^PlatformIOContext, allocator: mem.Allocator) {
        uring.destroy(&ctx.ring)
        queue.destroy(&ctx.unqueued)
    }

    @(private)
    _close_accept_loop :: proc(ctx: ^PlatformIOContext) {
        ctx.accept_loop_closed = true
    }

    @(private)
    _disable_read_interest :: proc(ctx: ^PlatformIOContext, conn: net.TCP_Socket) -> bool {
        unimplemented()
    }

    @(private)
    _unregister_client :: proc(ctx: ^PlatformIOContext, conn: net.TCP_Socket) -> bool {
        // we could issue a uring.async_cancel but the requests are identified by their user data,
        // which we do not store, so all we do is just stop issuing sqes
        return true
    }

    @(private)
    _await_io_completions :: proc(ctx: ^PlatformIOContext, sink: ^CompletionSink, timeout_ms: int) -> (ok: bool) {
        // wait timeout, requires a kernel version >= 5.11
        timeout: ^linux.Time_Spec = nil
        if timeout_ms != TIMEOUT_INFINITE {
            timeout = &linux.Time_Spec { time_nsec = uint(timeout_ms) * 1000 * 1000 }
        }

        // iterating over queue.pop_front_safe and calling _push_to_uring may extend unqueued list, thus making us loop forever
        for i := 0; i < queue.len(ctx.unqueued); i += 1 {
            _io_push_to_uring(ctx, **queue.pop_front(&ctx.unqueued))
        }
        
        enter2_errno: linux.Errno
        for {
            _, enter2_errno = uring.submit(&ctx.ring, wait_nr=1, timeout=timeout)
            if enter2_errno != .EINTR do break
        }
        if enter2_errno != .NONE {
            _log_error(enter2_errno, "failed to enter uring")
            return false
        }

        cqes := make([]linux.IO_Uring_CQE, _sink_free_space(sink^), context.temp_allocator)
        ncopied := uring.copy_cqes_ready(&ctx.ring, cqes)
        for cqe in cqes[:ncopied] {
            if cqe.user_data == WAKEUP_USER_DATA do continue
            
            ctrl := cast(^IOOperation) uintptr(cqe.user_data)
            switch &ctrl in ctrl {
            case IORecv:
                _process_recv_cqe(ctx, ctrl, cqe.res)
                // freed with _release_recv_buf()
            case IOSend:
                _process_send_cqe(ctx, &ctrl, cqe.res)
            case IOAccept:
                defer free(&ctrl, ctx.allocator)
                if ctx.accept_loop_closed do continue

                _process_accept_cqe(ctx, ctrl, cqe.res)
            case: panic("invalid union tag")
            }
        }
        
        return true
    }
    
    @(private)
    _release_recv_buf :: proc(ctx: ^PlatformIOContext, buf: []u8) {
        // offset ptr to wrapping allocation containing io control block
        ptr := uintptr(raw_data(buf)) - size_of(IOOperation)
        free(rawptr(ptr), ctx.allocator)
    }

    @(private)
    _submit_write_vectored :: proc(ctx: ^PlatformIOContext, sock: net.TCP_Socket, bufs: [][]u8) -> bool {
        ctrlp, ctrl, ancillary := _alloc_control_with_data(ctx, IOSend, len(bufs) * size_of(linux.IO_Vec))
        ctrl.msghdr.iov = mem.slice_ptr(cast(^linux.IO_Vec)raw_data(ancillary), len(bufs))
        iovecs := transmute([]linux.IO_Vec)bufs
        copy(ctrl.msghdr.iov, iovecs)

        ctrl.sock = linux.Fd(sock)
        
        _io_push_to_uring(ctx, ctrlp, linux.Fd(sock))
        return true
    }

    @(private)
    _wakeup :: proc(ctx: ^PlatformIOContext) {
        _, ok := uring.nop(&ctx.ring, WAKEUP_USER_DATA)
        // TODO: do this in a more elegant way, we cant really append to ctx.unqueued as this is only submitted
        // on an _await_io_completions, which this call is supposed to unblock
        assert(ok, "wakeup would cause sq to overflow")
        uring.submit(&ctx.ring, wait_nr=0) // flush
    }

    @(private="file")
    _log_error :: proc(errno: linux.Errno, message: string, level := ERROR_LOG_LEVEL) {
        log.logf(level, "%s: %s", message, os.error_string(errno))
    }

    // //////////////////////////////
    // IO OPERATIONS
    // //////////////////////////////

    @(private="file")
    _io_push_to_uring :: proc(ctx: ^PlatformIOContext, op: ^IOOperation, fd: linux.Fd) {
        tracy.Zone()
    
        user_data := u64(uintptr(op))
        sqe: ^linux.IO_Uring_SQE = ---
        did_append: bool
        
        switch &op in op {
        case IORecv:
            sqe, did_append = uring.recv(&ctx.ring, user_data, fd, op.recv_buf, {.NOSIGNAL}, poll_first=false)
        case IOSend:
            sqe, did_append = uring.sendmsg(&ctx.ring, user_data, fd, &op.msghdr, {.NOSIGNAL}, poll_first=false)
        case IOAccept:
            client_flags := linux.Socket_FD_Flags { .NONBLOCK, .CLOEXEC }
            sqe, did_append = uring.accept(&ctx.ring, user_data, ctx.server_sock, &op.dst_addr, &op.addr_len, client_flags, file_index=0)
        case:
            panic("union variant tag was not set")
        }

        if !did_append {
            // sq ring full, try to make space
            _, _ = uring.submit(&ctx.ring, wait_nr=0)
            queue.append(&ctx.unqueued, UnqueuedOperation { op, fd })
        }
    }
    
    @(private="file")
    _initiate_accept :: proc(ctx: ^PlatformIOContext) {
        tracy.Zone()
        
        ctrlp, ctrl := _alloc_control(ctx, IOAccept)
        ctrl.addr_len = i32(size_of(ctrl.dst_addr))

        _io_push_to_uring(ctx, ctrlp, ctx.server_sock)
    }

    @(private="file")
    _process_accept_cqe :: proc(ctx: ^PlatformIOContext, ctrl: IOAccept, ret: i32) {
        tracy.Zone()
        
        if ret < 0 {
            // TODO: standardize this error handling behaviour across all platforms
            _log_error(linux.Errno(-ret), "accept did not complete successfully")
            return
        }
        _initiate_recv(ctx, linux.Fd(ret))

        _emit_completion(ctx, Completion {
            operation = .NewConnection,
            socket = net.TCP_Socket(ret),
            endpoint = _sockaddr_to_endpoint(ctrl.dst_addr),
        })

        if !ctx.accept_loop_closed {
            _initiate_accept(ctx)
        }
    }
    
    @(private="file")
    _initiate_recv :: proc(ctx: ^PlatformIOContext, sock: linux.Fd) {
        tracy.Zone()

        ctrlp, ctrl, recv_buf := _alloc_control_with_data(ctx, IORecv, RECV_BUF_SIZE)

        ctrl.sock = sock
        ctrl.recv_buf = recv_buf

        _io_push_to_uring(ctx, ctrlp, sock)
    }

    @(private="file")
    _process_recv_cqe :: proc(ctx: ^PlatformIOContext, ctrl: IORecv, ret: i32) {
        tracy.Zone()

        if ret < 0 {
            _log_error(linux.Errno(-ret), "recv did not complete successfully")
            _release_recv_buf(ctx, ctrl.recv_buf)
            _emit_completion(ctx, Completion {
                socket = net.TCP_Socket(ctrl.sock),
                operation = .Error,
            })
            return
        }

        if ret == 0 {
            _emit_completion(ctx, Completion {
                socket = net.TCP_Socket(ctrl.sock),
                operation = .PeerHangup,
            })
            return
        }

        _emit_completion(ctx, Completion {
            socket = net.TCP_Socket(ctrl.sock),
            operation = .Read,
            buf = ctrl.recv_buf[:ret],
        })
        
        _initiate_recv(ctx, ctrl.sock)
    }

    @(private="file")
    _process_send_cqe :: proc(ctx: ^PlatformIOContext, ctrl: ^IOSend, ret: i32) {
        tracy.Zone()

        if ret < 0 {
            _log_error(linux.Errno(-ret), "sendmsg did not complete successfully")

            for _, i in ctrl.msghdr.iov {
                submitted_buf := _io_send_current_buffer(ctrl^, i)
                comp := Completion {
                    socket=net.TCP_Socket(ctrl.sock),
                    operation=.Error,
                    buf=submitted_buf,
                }
                _emit_completion(ctx, comp)
            }
            return
        }

        _advance_send_cursor(ctx, ctrl, written=int(ret))

        if len(ctrl.msghdr.iov) == 0 {
            // fully submitted, unsent part is empty
            free(ctrl, ctx.allocator)
        } else {
            // enqueue again in case of partial write
            _io_push_to_uring(ctx, cast(^IOOperation)ctrl, ctrl.sock)
        }
    }

    // Advances the send cursor by `written` bytes.
    // After returning, ctrl describes only the remaining unsent bytes:
    //
    //   - ctrl.msghdr.iov[0] points to the first unsent byte.
    //   - ctrl.buf_idx is the index of the current original buffer.
    //   - ctrl.buf_off is the offset of the first unsent byte within that buffer.
    //
    // If all buffers have been consumed, ctrl.msghdr.iov is empty.
    @(private="file")
    _advance_send_cursor :: proc(ctx: ^PlatformIOContext, cursor: ^IOSend, written: int) {
        remaining := written

        for remaining > 0 {
            vec := &cursor.msghdr.iov[0]

            // bytes still remaining in the current original buffer
            unsent := int(vec.len)
            if remaining < unsent {
                // partial write inside current buffer
                vec.base = mem.ptr_offset(vec.base, remaining)
                vec.len -= uint(remaining)

                cursor.buf_off += u32(remaining)
                break
            }

            // current buffer was fully transmitted
            remaining -= unsent
            submitted_buf := _io_send_current_buffer(cursor^, 0)

            _emit_completion(ctx, Completion {
                socket=net.TCP_Socket(cursor.sock),
                operation=.Write,
                buf=submitted_buf,
            })

            // advance to next buffer
            cursor.msghdr.iov = cursor.msghdr.iov[1:]
            cursor.buf_idx += 1
            cursor.buf_off = 0
        }
    }

    // Returns the original submitted buffer corresponding to ctrl.msghdr.iov[i].
    // The returned slice is identical to the slice originally passed to
    // _submit_write_vectored(), even if the first iovec has been advanced due to partial writes.
    @(private="file")
    _io_send_current_buffer :: proc(ctrl: IOSend, idx: int) -> []u8 {
        vec := ctrl.msghdr.iov[idx]

        if idx == 0 {
            base := mem.ptr_offset(vec.base, -int(ctrl.buf_off))
            len := int(vec.len) + int(ctrl.buf_off)
            return mem.slice_ptr(base, len)
        }
        return vec.base[:vec.len]
    }

    @(private="file")
    IOOperation :: union {
        IORecv,
        IOSend,
        IOAccept,
    }

    @(private="file")
    IORecv :: struct {
        sock: linux.Fd,
        recv_buf: []u8 `fmt:"-"`,
    }

    @(private="file")
    IOSend :: struct {
        sock: linux.Fd,
        // Iovecs are positioned so this msghdr represents the remaining unsent bytes, and can be sent as-is.
        // This means to get access to the original buffers submitted, we must ptr sub by buf_idx iovecs and buf_off bytes.
        msghdr: linux.Msg_Hdr,
        // Index of first msghdr.iov inside the original submitted buffers.
        buf_idx: u32,
        // Offset inside that buf_idx buffer.
        buf_off: u32,
    }

    @(private="file")
    IOAccept :: struct {
        dst_addr: linux.Sock_Addr_Any,
        // in/out param for accept sqe
        addr_len: i32,
    }
    
    @(private="file")
    _alloc_control :: #force_inline proc(ctx: ^PlatformIOContext, $T: typeid, loc := #caller_location) -> (^IOOperation, ^T)
        where intrinsics.type_is_variant_of(IOOperation, T) {
        tracy.Zone()

        #assert(intrinsics.type_is_union(IOOperation))

        ctrl := new(IOOperation, ctx.allocator) or_else panic(CTRL_OOM, loc=loc)
        ctrl^ = T{} // ensure union variant tag is set
        // returns control block ptr and ptr to inner union variant, odin stores union tags last, so should be safe
        #assert(intrinsics.type_union_tag_offset(IOOperation) > 0)
        return ctrl, cast(^T)ctrl
    }

    @(private="file")
    _alloc_control_with_data :: #force_inline proc(
        ctx: ^PlatformIOContext,
        $T: typeid,
        ancillary_size: int,
        loc := #caller_location,
    ) ->(^IOOperation, ^T, []u8) where intrinsics.type_is_variant_of(IOOperation, T) {
        tracy.Zone()

        data, err := mem.alloc_bytes_non_zeroed(
            size_of(IOOperation) + ancillary_size,
            alignment=align_of(IOOperation),
            allocator=ctx.allocator,
        )
        assert(err == .None, CTRL_OOM, loc=loc)

        ctrl := cast(^IOOperation)raw_data(data)
        ctrl^ = T{} // ensure union variant tag is set

        ancillary := data[size_of(IOOperation):]
        return ctrl, cast(^T)ctrl, ancillary
    }

    @(private="file")
    _sockaddr_to_endpoint :: proc(addr: linux.Sock_Addr_Any) -> net.Endpoint {
        #partial switch addr.family {
        case .INET:
            return net.Endpoint {
                address = net.IP4_Address(addr.ipv4.sin_addr),
                port = int(addr.ipv4.sin_port),
            }
        case .INET6:
            return net.Endpoint {
                address = net.IP6_Address(transmute([8]u16)addr.ipv6.sin6_addr),
                port = int(addr.ipv6.sin6_port),
            }
        case: panic("neither ipv4 nor ipv6 address passed")
        }
    }
}

