package crux

import "core:os"
import "core:log"
import "core:mem"
import "core:sync"
import "core:time"
import "core:c/libc"
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
}

main :: proc() {
    exitcode: ExitCode
    // NOTE: must be put before all other deferred statements
    defer os.exit(exitcode)

    when ODIN_DEBUG {
        allocator: mem.Tracking_Allocator
        mem.tracking_allocator_init(&allocator, context.allocator)
        defer mem.tracking_allocator_destroy(&allocator)
        context.allocator = mem.tracking_allocator(&allocator)

        defer {
            for _, leak in allocator.allocation_map {
                log.warnf("%v leaked %m", leak.location, leak.size)
            }
            for bad_free in allocator.bad_free_array {
                log.warnf("%v allocation %p was freed badly", bad_free.location, bad_free.memory)
            }
        }

        max_tsc_timeout :: time.Second / 2
        g_spall_ctx = spall.context_create("trace.spall", max_tsc_timeout) or_else panic("failed to setup spall")
        defer spall.context_destroy(&g_spall_ctx)

        backing_buf := make([]u8, spall.BUFFER_DEFAULT_SIZE)
        defer delete(backing_buf)
        g_spall_buf = spall.buffer_create(backing_buf, u32(sync.current_thread_id()))
        defer spall.buffer_destroy(&g_spall_ctx, &g_spall_buf)
    }
    
    log_opts := log.Options {.Level, .Thread_Id, .Terminal_Color}
    for &header in log.Level_Headers {
        header = header[:len(header) - len("--- ")]
    }

    context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Warning, log_opts)
    defer log.destroy_console_logger(context.logger)

    libc.signal(libc.SIGINT, proc "c" (_: i32) {
        spall.buffer_flush(&g_spall_ctx, &g_spall_buf)
        os.exit(0)
    })

    // TODO
    args, ok := parse_cli_args()
    log.info(args, ok)

    exitcode = run()
}

// Logs a fatal condition, which we cannot recover from.
// This proc always returns 1, for the sake of `return fatal("aa")`
@(require_results)
fatal :: proc(args: ..any, loc := #caller_location) -> ExitCode {
    log.fatal(..args, location=loc)
    return 1
}

@(no_instrumentation)
trace :: #force_inline proc(name := "", args := "", loc := #caller_location) -> bool {
    when ODIN_DEBUG {
        spall.SCOPED_EVENT(&g_spall_ctx, &g_spall_buf, name, args, loc)
    }
    return true
}

when ODIN_DEBUG {
    @(instrumentation_enter)
    spall_enter :: proc "contextless" (proc_addr, call_site_ret_addr: rawptr, loc: runtime.Source_Code_Location) {
        spall._buffer_begin(&g_spall_ctx, &g_spall_buf, "", "", loc)
    }

    @(instrumentation_exit)
    spall_exit :: proc "contextless" (proc_addr, call_site_ret_addr: rawptr, loc: runtime.Source_Code_Location) {
        spall._buffer_end(&g_spall_ctx, &g_spall_buf)
    }
}
