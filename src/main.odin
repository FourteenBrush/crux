package crux

import "core:os"
import "core:log"
import "core:mem"
import "core:time"
import "core:thread"

import "base:runtime"

import "lib:tracy"

_ :: mem
_ :: time
_ :: runtime

ExitCode :: int

main :: proc() {
    exitcode: ExitCode
    // NOTE: must be put before all other deferred statements
    defer os.exit(exitcode)

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

    log_opts := log.Options {.Level, .Thread_Id, .Terminal_Color}
    for &header in log.Level_Headers {
        header = header[:len(header) - len("--- ")]
    }

    // ensure from now on, no allocations are done with the default heap allocator
    context.allocator = mem.panic_allocator()

    context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Warning, log_opts, allocator=allocator)
    defer log.destroy_console_logger(context.logger, allocator=allocator)

    tracy.SetThreadName("main")

    // TODO
    args, ok := parse_cli_args()
    log.info(args, ok)

    workers: thread.Pool
    thread.pool_init(&workers, runtime.default_allocator(), os.processor_core_count() / 2)
    defer thread.pool_destroy(&workers)
    log.debug("created workers thread pool")

    exitcode = run(allocator)
}

// Logs a fatal condition, which we cannot recover from.
// This proc always returns 1, for the sake of `return fatal("aa")`
@(require_results)
fatal :: proc(args: ..any, loc := #caller_location) -> ExitCode {
    log.fatal(..args, location=loc)
    return 1
}
