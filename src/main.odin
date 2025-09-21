package crux

import "core:fmt"
import "core:os"
import "core:log"
import "core:mem"
import "core:time"
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

// log levels for logging packet transfer, these values are bigger than .Debug (1)
@(private) LOG_LEVEL_INBOUND :: log.Level(7)
@(private) LOG_LEVEL_OUTBOUND :: log.Level(8)
@(private) LOG_LEVEL_REACTOR_ERROR :: reactor.ERROR_LOG_LEVEL

main :: proc() {
    exit_success: bool
    // NOTE: must be put before all other deferred statements
    defer os.exit(0 if exit_success else 1)

    // in debug mode, wrap a tracking allocator around the dynamic arena
    when ODIN_DEBUG && !tracy.TRACY_ENABLE {
        tracking_alloc: back.Tracking_Allocator
        back.tracking_allocator_init(&tracking_alloc, context.allocator)
        defer back.tracking_allocator_destroy(&tracking_alloc)
        context.allocator = back.tracking_allocator(&tracking_alloc)
        defer back.tracking_allocator_print_results(&tracking_alloc, .Both)
    }

    when tracy.TRACY_ENABLE {
        context.allocator = tracy.MakeProfiledAllocator(
            self = &tracy.ProfiledAllocatorData{},
            callstack_size = 14,
            backing_allocator = context.allocator,
        )
    }

    back.register_segfault_handler()
    // context.assertion_failure_proc = back.assertion_failure_proc

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

    alloc_formatters := fmt._user_formatters == nil
    defer if alloc_formatters {
        delete(fmt._user_formatters^)
    }
    if alloc_formatters {
        formatters := make(map[typeid]fmt.User_Formatter)
        fmt.set_user_formatters(&formatters)
    }
    _register_user_formatters()

    // TODO
    // args, ok := parse_cli_args(allocator)

    context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Warning, log_opts)
    defer log.destroy_console_logger(context.logger)

    tracy.SetThreadName("main")

    exit_success = run()
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