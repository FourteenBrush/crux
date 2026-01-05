#+build linux 
package reactor

import "core:log"
import "core:fmt"
@(require) import "core:os"
@(require) import "core:sync"
@(require) import "core:net"
@(require) import "core:mem"
@(require) import "core:sys/linux"

@(require) import "lib:tracy"

when /*USE_IO_URING*/ true {

    // NOTE: must be kept relatively low due to mem limits (max locked pages, etc..), effectively
    // causing a memlock() to fail
    // TODO: document /etc/security/limits.conf fix
    @(private="file")
    SQ_INIT_ENTRIES :: 128
    #assert(SQ_INIT_ENTRIES & (SQ_INIT_ENTRIES - 1) == 0)
    
    // Accept flags stored in sqe.ioprio (torvalds:linux/tools/include/uapi/linux/io_uring.h)
    @(private="file")
    IORING_ACCEPT_MULTISHOT :: 1 << 0

    @(private)
    _IOContext :: struct {
        ring_fd: linux.Fd,
        server_sock: linux.Fd,

        sq: SubmissionQueue,
        cq: Queue,
        
        // Accepted client is stored here on a multishot accept()
        accepted_client: linux.Sock_Addr,
    }

    @(private)
    SubmissionQueue :: struct {
        using _: Queue,
        array: []u32,
        sqes: []linux.IO_Uring_SQE,
        to_submit: u32,
    }

    @(private)
    Queue :: struct {
        mmap_region: []u8,
        head: ^u32,
        tail: ^u32,
        mask: ^u32,
    }

    @(private)
    _create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: IOContext, ok: bool) {
        params := linux.IO_Uring_Params {}
        ring_fd, errno := linux.io_uring_setup(SQ_INIT_ENTRIES, &params)
        if errno != .NONE {
            _log_error(errno, "io_uring_setup() failed")
            
            mlock_caps: linux.RLimit
            linux.getrlimit(.MEMLOCK, &mlock_caps)
            fmt.printfln("max locked pages (bytes): %M/%M", mlock_caps.cur, mlock_caps.max)
            return
        }
        defer if !ok do linux.close(ring_fd)

        ctx.ring_fd = ring_fd
        
        // ring layouts: head, tail, mask, ...other metadata, actual data (indices for cq, cqes for cq)
        sq_size := uint(params.sq_off.array + params.sq_entries * size_of(u32))
        cq_size := uint(params.cq_off.cqes + params.cq_entries * size_of(linux.IO_Uring_CQE))

        mmap :: proc(size: uint, fd: linux.Fd, offset: i64, flags := linux.Map_Flags{}) -> (rawptr, bool) {
            ptr, map_err := linux.mmap(0, size, {.READ, .WRITE}, {.SHARED} | flags, fd, offset)
            if map_err != .NONE do return nil, false
            return ptr, true
        }

        // offsets are relative to mmap base, as they do not overlap between queues
        init_queue :: proc(q: ^Queue, offsets: $T, mmap_base: rawptr, mmap_size: uint) {
            q.mmap_region = mem.slice_ptr(cast(^u8)mmap_base, int(mmap_size))
            base := cast([^]u32)mmap_base
            q.head = &base[offsets.head / size_of(u32)]
            q.tail = &base[offsets.tail / size_of(u32)]
            q.mask = &base[offsets.ring_mask / size_of(u32)]
        }

        sq_base, cq_base: rawptr
        if .SINGLE_MMAP in params.features {
            // sq and cq offsets do not overlap inside fd pseudo file
            size := max(cq_size, sq_size)
            sq_base = mmap(size, ring_fd, linux.IORING_OFF_SQ_RING, {.POPULATE}) or_return
            defer if !ok do linux.munmap(sq_base, size)
            cq_base = sq_base
        } else {
            sq_base = mmap(sq_size, ring_fd, linux.IORING_OFF_SQ_RING, {.POPULATE}) or_return
            defer if !ok do linux.munmap(sq_base, sq_size)

            cq_base = mmap(cq_size, ring_fd, linux.IORING_OFF_CQ_RING, {.POPULATE}) or_return
            defer if !ok do linux.munmap(cq_base, cq_size)
        }
        init_queue(&ctx.sq, params.sq_off, sq_base, sq_size)
        init_queue(&ctx.cq, params.cq_off, cq_base, cq_size)

        sqes_size := uint(params.sq_entries) * size_of(linux.IO_Uring_SQE)
        sqes := mmap(sqes_size, ring_fd, linux.IORING_OFF_SQES) or_return
        defer if !ok do linux.munmap(sqes, sqes_size)

        ctx.sq.sqes = mem.slice_ptr(cast(^linux.IO_Uring_SQE) sqes, int(params.sq_entries))
        
        // install accept() handler
        // TODO(urgent): we are moving ctx
        _submit_multishot_accept(&ctx) or_return

        return ctx, true
    }

    @(private)
    _destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
        linux.munmap(raw_data(ctx.sq.mmap_region), len(ctx.sq.mmap_region))
        if raw_data(ctx.cq.mmap_region) != raw_data(ctx.sq.mmap_region) {
            linux.munmap(raw_data(ctx.cq.mmap_region), len(ctx.cq.mmap_region))
        }
        linux.munmap(raw_data(ctx.sq.sqes), len(ctx.sq.sqes) * size_of(ctx.sq.sqes[0]))
        linux.close(ctx.ring_fd)
    }

    @(private)
    _register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
        tracy.Zone()
        fd := linux.Fd(client)

        _submit_read(ctx, fd)
        return false
    } 

    @(private)
    _unregister_client :: proc(ctx: ^IOContext, conn: net.TCP_Socket) -> bool {
        tracy.Zone()
        return false
    }
    
    @(private="file")
    _submit_read :: proc(ctx: ^IOContext, fd: linux.Fd) -> bool {
        sqe := _get_sqe(ctx) or_return
        sqe.opcode = .READ
        sqe.fd = fd
        buf := make([]u8, 2048, allocator=os.heap_allocator())
        sqe.addr = cast(u64) uintptr(raw_data(buf))
        sqe.len = cast(u32) len(buf)
        sqe.off = 0
        
        _submit_sqe(ctx, sqe^)
        return true
    }

    @(private="file")
    _submit_multishot_accept :: proc(ctx: ^IOContext) -> bool {
        sqe := _get_sqe(ctx) or_return
        sqe.fd = ctx.server_sock
        sqe.addr = cast(u64) uintptr(&ctx.accepted_client)
        sqe.addr2 = size_of(linux.Sock_Addr)
        sqe.accept_flags = {}
        sqe.ioprio |= IORING_ACCEPT_MULTISHOT
        
        _submit_sqe(ctx, sqe^)
        return true
    }
    
    // Returns `nil` when the submission queue is full.
    @(private="file")
    _get_sqe :: proc(ctx: ^IOContext) -> (^linux.IO_Uring_SQE, bool) {
        sq := &ctx.sq
        head := sync.atomic_load_explicit(sq.head, .Acquire)
        tail := sync.atomic_load_explicit(sq.tail, .Acquire)

        if head == tail {
            return nil, false
        }

        return &sq.sqes[tail & ctx.sq.mask^], true
    }

    @(private="file")
    _submit_sqe :: proc(ctx: ^IOContext, sqe: linux.IO_Uring_SQE) {
        tail := sync.atomic_load_explicit(ctx.sq.tail, .Acquire)
        
        idx := tail & ctx.sq.mask^

        ctx.sq.sqes[idx] = sqe
        sync.atomic_store_explicit(&ctx.sq.array[idx], idx, .Release)
        sync.atomic_store_explicit(ctx.sq.tail, tail + 1, .Release)
        ctx.to_submit += 1
    }

    @(private)
    _await_io_completions :: proc(ctx: ^IOContext, completions_out: []Completion, timeout_ms: int) -> (n: int, ok: bool) {
        tracy.Zone()

        nconsumed, errno := linux.io_uring_enter2(ctx.ring_fd, ctx.sq.to_submit, 1, {.GETEVENTS, .EXT_ARG}, &linux.IO_Uring_Getevents_Arg {
            // pass wait timeout, requires EXT_ARG and a kernel version >= 5.11
            ts = &linux.Time_Spec { time_nsec = 1 * 1000 * 1000 },
        })
        if errno != .NONE && errno != .ETIME do return
        ctx.sq.to_submit = 0
        
        return 0, true
    }

    @(private)
    _release_recv_buf :: proc(ctx: ^IOContext, buf: []u8) {
        delete(buf, os.heap_allocator())
    }

    @(private)
    _submit_write_copy :: proc(ctx: ^IOContext, conn: net.TCP_Socket, data: []u8) -> bool {
        return false
    }

    @(private="file")
    _log_error :: proc(errno: linux.Errno, message: string, level := ERROR_LOG_LEVEL) {
        log.logf(level, "%s: %s", message, errno)
    }
}

