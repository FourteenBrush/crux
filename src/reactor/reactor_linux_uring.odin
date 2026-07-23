#+build linux
#+vet explicit-allocators
package reactor

@(require) import "core:os"
@(require) import "core:fmt"
@(require) import "core:log"
@(require) import "core:net"
@(require) import "core:mem"
@(require) import "core:sys/linux"
@(require) import "core:sys/linux/uring"

@(require) import "lib:tracy"

// TODO: VV
when true {

    @(private)
    _TIMEOUT_INFINITE :: -1

    @(private="file")
    _IOCB_OOM :: "OOM while allocating io control block"

    // NOTE: must be kept relatively low due to mem limits (max locked pages, etc..), effectively
    // causing a memlock() to fail
    // TODO: document /etc/security/limits.conf fix
    @(private="file")
    SQ_INIT_ENTRIES :: 128
    #assert(SQ_INIT_ENTRIES & (SQ_INIT_ENTRIES - 1) == 0)
    #assert(SQ_INIT_ENTRIES < uring.MAX_ENTRIES)

    @(private)
    PlatformIOContext :: struct {
        server_sock: linux.Fd,
        allocator: mem.Allocator,
        ring: uring.Ring,
        accept_loop_closed: bool,
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

        _initiate_accept(&ctx) or_return
        
        return ctx, true
    }
    
    @(private)
    _destroy_io_context :: proc(ctx: ^PlatformIOContext, allocator: mem.Allocator) {
        uring.destroy(&ctx.ring)
    }

    @(private)
    _close_accept_loop :: proc(ctx: ^PlatformIOContext) {
        ctx.accept_loop_closed = true
    }

    @(private="file", require_results)
    _register_client :: proc(ctx: ^PlatformIOContext, client: linux.Fd) -> bool {
        tracy.Zone()

        recv_buf, alloc_err := mem.alloc_bytes_non_zeroed(RECV_BUF_SIZE, align_of(1), ctx.allocator)
        fmt.assertf(alloc_err == .None, "OOM: %v", alloc_err)
        // TODO: multishot reads with buffer pool
        _, ok := uring.read(&ctx.ring, 0, client, recv_buf, offset=0)
        return ok
    } 

    @(private)
    _disable_read_interest :: proc(ctx: ^PlatformIOContext, conn: net.TCP_Socket) -> bool {
        unimplemented()
    }

    @(private)
    _unregister_client :: proc(ctx: ^PlatformIOContext, conn: net.TCP_Socket) -> bool {
        return false
    }

    @(private)
    _await_io_completions :: proc(ctx: ^PlatformIOContext, sink: ^CompletionSink, timeout_ms: int) -> (ok: bool) {
        // wait timeout, requires a kernel version >= 5.11
        timeout: ^linux.Time_Spec = nil
        if timeout_ms != TIMEOUT_INFINITE {
            timeout = &linux.Time_Spec { time_nsec = uint(timeout_ms) * 1000 * 1000 }
        }
        
        enter2_errno: linux.Errno
        for {
            _, enter2_errno = uring.submit(&ctx.ring, wait_nr=1, timeout=timeout)
            if enter2_errno != .EINTR do break
        }
        if enter2_errno != .NONE do return

        cqes := make([]linux.IO_Uring_CQE, len(sink.out) - sink.nproduced, context.temp_allocator)
        ncopied := uring.copy_cqes_ready(&ctx.ring, cqes)
        for cqe in cqes[:ncopied] {
            cb := cast(^IOOperation) uintptr(cqe.user_data)
            switch cb in cb {
            case IORead:
            case IOWrite:
            case IOAccept:
                _process_accept(ctx, cb, cqe.res)
            }
        }
        
        return true
    }
    
    @(private="file")
    _initiate_accept :: proc(ctx: ^PlatformIOContext) -> bool {
        cb := new(IOAccept, ctx.allocator) or_else panic(_IOCB_OOM)
        cb.addr_len = i32(size_of(cb.dst_addr))
        _, ok := uring.accept(&ctx.ring, u64(uintptr(cb)), linux.Fd(ctx.server_sock), &cb.dst_addr, &cb.addr_len, {}, file_index=0)
        return ok
    }

    @(private="file")
    _process_accept :: proc(ctx: ^PlatformIOContext, cb: IOAccept, ret: i32) {
        if ret < 0 {
            _log_error(linux.Errno(-ret), "accept did not complete successfully")
            return
        }
        // TODO: standardize this error handling behaviour across all platforms
        if registration_ok := _register_client(ctx, linux.Fd(ret)); !registration_ok {
            log.warn("failed to accept client")
            return
        }
    }

    @(private="file")
    IOOperation :: union {
        IORead,
        IOWrite,
        IOAccept,
    }

    @(private="file")
    IORead :: struct {
        recv_buf: []u8,
    }

    @(private="file")
    IOWrite :: struct {
        buf: []u8,
        offset: u32,
    }

    @(private="file")
    IOAccept :: struct {
        dst_addr: linux.Sock_Addr_Any,
        // in/out param for accept sqe
        addr_len: i32,
    }

    @(private)
    _release_recv_buf :: proc(ctx: ^PlatformIOContext, buf: []u8) {
        delete(buf, ctx.allocator)
    }

    @(private)
    _submit_write_vectored :: proc(ctx: ^PlatformIOContext, conn: net.TCP_Socket, bufs: [][]u8) -> bool {
        unimplemented()
    }

    @(private)
    _wakeup :: proc(ctx: ^PlatformIOContext) {
        unimplemented()
    }

    @(private="file")
    _log_error :: proc(errno: linux.Errno, message: string, level := ERROR_LOG_LEVEL) {
        log.logf(level, "%s: %s", message, os.error_string(errno))
    }
}

