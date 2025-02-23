package crux

import "core:os"
import "core:log"
import "core:mem"
import "core:sync"
import "core:time"
import "core:sys/linux"
import "core:prof/spall"

import "base:runtime"

_ :: mem
_ :: sync
_ :: spall
_ :: runtime

ExitCode :: int

when ODIN_DEBUG {
    @(thread_local)
    g_spall_buf: spall.Buffer
    g_spall_ctx: spall.Context
    g_spall_mtx: sync.Mutex
    g_in_write := false
}

main :: proc() {
    exitcode: ExitCode
    // NOTE: must be put before all other deferred statements
    defer os.exit(exitcode)

    pool: mem.Dynamic_Arena
    mem.dynamic_arena_init(&pool, context.allocator, context.allocator, block_size=spall.BUFFER_DEFAULT_SIZE, alignment=size_of(rawptr))
    allocator := mem.dynamic_arena_allocator(&pool)
    defer mem.dynamic_arena_destroy(&pool)

    // in debug mode, wrap a tracking allocator around the dynamic arena
    when ODIN_DEBUG {
        tracking_alloc: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking_alloc, allocator, allocator)
        tracking_alloc.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
        defer mem.tracking_allocator_destroy(&tracking_alloc)
        allocator = mem.tracking_allocator(&tracking_alloc)

        defer {
            for _, leak in tracking_alloc.allocation_map {
                log.warnf("%v leaked %m", leak.location, leak.size)
            }
            for bad_free in tracking_alloc.bad_free_array {
                log.warnf("%v allocation %p was freed badly", bad_free.location, bad_free.memory)
            }
        }

        max_tsc_timeout :: time.Second / 2
        g_spall_ctx = spall.context_create("trace.spall", max_tsc_timeout) or_else panic("failed to setup spall")
        defer spall.context_destroy(&g_spall_ctx)

        backing_buf := make([]u8, spall.BUFFER_DEFAULT_SIZE, allocator)
        defer delete(backing_buf)
        g_spall_buf = spall.buffer_create(backing_buf, u32(sync.current_thread_id()))
        defer spall.buffer_destroy(&g_spall_ctx, &g_spall_buf)
    }

    log_opts := log.Options {.Level, .Thread_Id, .Terminal_Color}
    for &header in log.Level_Headers {
        header = header[:len(header) - len("--- ")]
    }

    // FIXME: implicit allocation which doesnt allow us to pass an allocator
    // currently segfaults due to our mem.panic_allocator()
    context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Warning, log_opts, allocator=allocator)
    defer log.destroy_console_logger(context.logger, allocator=allocator)

    // ensure from now on, no allocations are done with the default heap allocator
    context.allocator = mem.panic_allocator()

    action := linux.Sig_Action([0]u8) {
        handler = proc "c" (sig: linux.Signal) {
            // TODO: theres some issue where the profiler data is sometimes corrupted when ctrl+c ing
            // maybe because a write got interrupted by a SIGINT?
            context = runtime.default_context()
            runtime.println_any("in_write:", g_in_write)
            spall.buffer_flush(&g_spall_ctx, &g_spall_buf)
            //spall.buffer_destroy(&g_spall_ctx, &g_spall_buf)
            //spall.context_destroy(&g_spall_ctx)
            g_running = false
            //os.exit(0)
        },
        flags = { .RESTART },
    }
    old_action: ^linux.Sig_Action([0]u8) = nil
    if linux.rt_sigaction(.SIGINT, &action, old_action) != nil {
        _ = fatal("sigaction")
    }

    // TODO
    args, ok := parse_cli_args()
    log.info(args, ok)

    exitcode = run(allocator)
}

// Logs a fatal condition, which we cannot recover from.
// This proc always returns 1, for the sake of `return fatal("aa")`
@(require_results)
fatal :: proc(args: ..any, loc := #caller_location) -> ExitCode {
    log.fatal(..args, location=loc)
    return 1
}

@(no_instrumentation, deferred_in=buffer_end)
SCOPED_EVENT :: proc(name := "", args := "", loc := #caller_location) -> bool {
    when ODIN_DEBUG {
        lname := name if name != "" else loc.procedure
        g_in_write = true
        sync.mutex_guard(&g_spall_mtx)
        spall._buffer_begin(&g_spall_ctx, &g_spall_buf, lname, args, loc)
    }
    return true
}

// Basically a copy of spall._scoped_buffer_end
@(no_instrumentation, private)
buffer_end :: proc(_, _: string, _: runtime.Source_Code_Location) {
    when ODIN_DEBUG {
        //sync.mutex_guard(&g_spall_mtx)
        spall._buffer_end(&g_spall_ctx, &g_spall_buf)
        g_in_write = false
    }
}

when ODIN_DEBUG {
    @(instrumentation_enter)
    spall_enter :: proc "contextless" (proc_addr, call_site_ret_addr: rawptr, loc: runtime.Source_Code_Location) {
        spall._buffer_begin(&g_spall_ctx, &g_spall_buf, "", "", loc)
        g_in_write = true
    }

    @(instrumentation_exit)
    spall_exit :: proc "contextless" (proc_addr, call_site_ret_addr: rawptr, loc: runtime.Source_Code_Location) {
        spall._buffer_end(&g_spall_ctx, &g_spall_buf)
        g_in_write = false
    }
}
