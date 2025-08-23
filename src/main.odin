package crux

import "core:os"
import "core:log"
import "core:mem"
import "core:sync"
import "core:time"
import "core:sys/posix"

import "base:runtime"

// import "lib:tracy"

_ :: mem
_ :: time
_ :: runtime

// log levels for logging packet transfer, these values are bigger than .Debug (1)
@(private) LOG_LEVEL_INBOUND :: log.Level(8)
@(private) LOG_LEVEL_OUTBOUND :: log.Level(9)

@(private="file")
g_server_context: runtime.Context
@(private="file")
g_continue_running := true

main :: proc() {
    exit_success: bool
    // NOTE: must be put before all other deferred statements
    defer os.exit(0 if exit_success else 1)

    pool: mem.Dynamic_Arena
    mem.dynamic_arena_init(
      &pool, context.allocator, context.allocator,
      alignment=runtime.MAP_CACHE_LINE_SIZE,
    )
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
    }

    log_opts := log.Options {.Level, .Terminal_Color}
    // remove "---" and spacing inside []
    log.Level_Headers = {
         0..<7  = "[DEBUG] ",
        LOG_LEVEL_INBOUND  = "[INB]   ",
        LOG_LEVEL_OUTBOUND = "[OUTB]  ",
    	10..<20 = "[INFO]  ",
    	20..<30 = "[WARN]  ",
    	30..<40 = "[ERROR] ",
    	40..<50 = "[FATAL] ",
    }

    g_server_context = context
    posix.signal(.SIGINT, proc "c" (_: posix.Signal) {
        context = g_server_context
        sync.atomic_store_explicit(&g_continue_running, false, .Release)
    })

    // ensure all allocators are explicitly used
    context.allocator = mem.panic_allocator()

    context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Warning, log_opts, allocator=allocator)
    defer log.destroy_console_logger(context.logger, allocator=allocator)

    // tracy.SetThreadName("main")

    // TODO
    args, ok := parse_cli_args(allocator)

    exit_success = run(allocator, execution_permit=&g_continue_running)
}