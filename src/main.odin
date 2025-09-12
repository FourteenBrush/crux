package crux

import "core:fmt"
import "core:os"
import "core:log"
import "core:mem"
import "core:sync"
import "core:time"
import "core:c/libc"
import "base:runtime"
import "core:prof/spall"
import "core:encoding/uuid"


import "src:reactor"

import "lib:back"
import "lib:tracy"

_ :: mem
_ :: time
_ :: spall
_ :: runtime

@(private="file")
CRUX_PROFILE :: #config(CRUX_PROFILE, false)

// log levels for logging packet transfer, these values are bigger than .Debug (1)
@(private) LOG_LEVEL_INBOUND :: log.Level(7)
@(private) LOG_LEVEL_OUTBOUND :: log.Level(8)
@(private) LOG_LEVEL_REACTOR_ERROR :: reactor.ERROR_LOG_LEVEL

@(private="file")
g_continue_running := true

main :: proc() {
    exit_success: bool
    // NOTE: must be put before all other deferred statements
    defer os.exit(0 if exit_success else 1)

    pool: mem.Dynamic_Arena
    mem.dynamic_arena_init(
      &pool, context.allocator, context.allocator,
      block_size=spall.BUFFER_DEFAULT_SIZE when CRUX_PROFILE else mem.DYNAMIC_ARENA_BLOCK_SIZE_DEFAULT,
      alignment=runtime.MAP_CACHE_LINE_SIZE,
    )
    allocator := mem.dynamic_arena_allocator(&pool)
    defer mem.dynamic_arena_destroy(&pool)

    // in debug mode, wrap a tracking allocator around the dynamic arena
    when ODIN_DEBUG && !CRUX_PROFILE {
        tracking_alloc: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking_alloc, allocator, os.heap_allocator())
        tracking_alloc.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
        defer mem.tracking_allocator_destroy(&tracking_alloc)
        allocator = mem.tracking_allocator(&tracking_alloc)

        defer {
            for _, leak in tracking_alloc.allocation_map {
                fmt.eprintfln("%v leaked %m", leak.location, leak.size)
            }
            for bad_free in tracking_alloc.bad_free_array {
                fmt.eprintfln("%v allocation %p was freed badly", bad_free.location, bad_free.memory)
            }
        }
    }

    when tracy.TRACY_ENABLE {
        allocator = tracy.MakeProfiledAllocator(
            self = &tracy.ProfiledAllocatorData{},
            callstack_size = 14,
            backing_allocator = allocator,
        )
    }

    back.register_segfault_handler()
    context.assertion_failure_proc = back.assertion_failure_proc

    log_opts := log.Options {.Level, .Terminal_Color}

    // define log levels in order of importance
    log.Level_Headers = {
        0..<6  = "[DEBUG] ",
        LOG_LEVEL_INBOUND  = "[INB]   ",
        LOG_LEVEL_OUTBOUND = "[OUTB]  ",
        LOG_LEVEL_REACTOR_ERROR = "[IO]    ",
    	10..<20 = "[INFO]  ",
    	20..<30 = "[WARN]  ",
    	30..<40 = "[ERROR] ",
    	40..<50 = "[FATAL] ",
    }

    libc.signal(libc.SIGINT, proc "c" (_sig: i32) {
        sync.atomic_store_explicit(&g_continue_running, false, .Release)
    })

    defer if fmt._user_formatters == nil {
        delete(fmt._user_formatters^)
    }
    if fmt._user_formatters == nil {
        formatters := make(map[typeid]fmt.User_Formatter)
        fmt.set_user_formatters(&formatters)
    }
    _register_user_formatters()

    // ensure all allocators are explicitly used
    context.allocator = mem.panic_allocator()

    context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Warning, log_opts, allocator=allocator)
    defer log.destroy_console_logger(context.logger, allocator=allocator)

    tracy.SetThreadName("main")

    // TODO
    // args, ok := parse_cli_args(allocator)

    exit_success = true
    exit_success = run(allocator, execution_permit=&g_continue_running)
}

@(private="file")
_register_user_formatters :: proc() {
    fmt.register_user_formatter(Utf16String, proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
        str := (^Utf16String)(arg.data)^
        // TODO: only correctly formatted on some terminals
        fmt.wprintf(fi.writer, "%s", cast([]u8) str)
        return true
    })
    fmt.register_user_formatter(uuid.Identifier, proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
        id := (^uuid.Identifier)(arg.data)^
        buf: [36]u8
        fmt.wprint(fi.writer, uuid.to_string_buffer(id, buf[:]))
        return true
    })
}