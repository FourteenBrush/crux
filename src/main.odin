package crux

import "core:net"
import "core:os"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:time"
import "core:strings"
import "core:terminal"
import "core:encoding/uuid"
import "core:terminal/ansi"

import "src:reactor"

import "lib:back"
import "lib:tracy"

_ :: mem

@(private) LOG_LEVEL :: log.Level.Debug when ODIN_DEBUG else log.Level.Info

// log levels for logging packet transfer, these values are bigger than .Debug (1)
@(private) LOG_LEVEL_INBOUND :: log.Level(7)
@(private) LOG_LEVEL_OUTBOUND :: log.Level(8)
@(private) LOG_LEVEL_REACTOR_ERROR :: reactor.ERROR_LOG_LEVEL

main :: proc() {
    exit_success := false
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
    // TODO: fix panic() callsite recursively calling into panic allocator inside handler, causing stack overflow
    // context.assertion_failure_proc = back.assertion_failure_proc

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
    
    // NOTE: log package respects NO_COLOR env var and will not output colors if this is set
    log_opts := log.Options {.Level, .Terminal_Color}

    // define log levels in order of importance
    // FIXME: is there a way to assign log levels lower than .Debug (is has value 0 and log.Level is backed by uint)
    log.Level_Headers = {
        0..<6  = "debug",
        LOG_LEVEL_INBOUND  = "inbound",
        LOG_LEVEL_OUTBOUND = "outbound",
        LOG_LEVEL_REACTOR_ERROR = "reactor",
    	10..<20 = "info",
    	20..<30 = "warn",
    	30..<40 = "error",
    	40..<50 = "fatal",
    }
    context.logger = create_logger(LOG_LEVEL, log_opts, "core")
    
    tracy.SetThreadName("main")
    
    endpoint := net.Endpoint {
        // address = net.IP4_Loopback,
        address = net.IP4_Address { 0, 0, 0, 0 },
        port = 25565,
    }
    
    server_sock, net_err := net.listen_tcp(endpoint, backlog=128)
    if net_err != nil {
        log.error("failed to create server socket:", net_err)
        return
    }
    defer if !exit_success do net.close(server_sock)

    net_err = net.set_blocking(server_sock, false)
    if net_err != nil {
        log.error("failed to set server socket to non blocking:", net_err)
        return
    }

    exit_success = run(endpoint, server_sock)
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

// Inputs:
//  - `subsystem`: the 'name' of the logger to be used as prefix, e.g. "network", "server", etc.
@(private)
create_logger :: proc(level: log.Level, options: log.Options, subsystem: string) -> log.Logger {
    return log.Logger {
        data = raw_data(subsystem),
        lowest_level = level,
        options = options,
        procedure = _logger_proc,
    }
}

@(private="file")
_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
    options := options
    
    handle := os.stdout if level < .Error else os.stderr
    if terminal.color_enabled && !terminal.is_terminal(handle) {
        options -= {.Terminal_Color}
    }
    
    header_buf: [1024]u8
    header_sb := strings.builder_from_bytes(header_buf[:])
    
    when time.IS_SUPPORTED {
        log.do_time_header(options, &header_sb, time.now())
    }
    
    log.do_location_header(options, &header_sb, location)
    if .Thread_Id in options {
        fmt.sbprintf(&header_sb, "[{}] ", os.get_current_thread_id())
    }
    
    RESET :: ansi.CSI + ansi.RESET           + ansi.SGR
    GRAY  :: ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR
    MAGENTA, CYAN, YELLOW, GREEN, ORANGE, RED: string
    if terminal.color_depth == .True_Color {
        MAGENTA  = ansi.CSI + ansi.FG_COLOR_24_BIT + ";190;167;225" + ansi.SGR
        CYAN     = ansi.CSI + ansi.FG_COLOR_24_BIT + ";100;163;194" + ansi.SGR
        YELLOW   = ansi.CSI + ansi.FG_COLOR_24_BIT + ";195;217;146" + ansi.SGR
        GREEN    = ansi.CSI + ansi.FG_COLOR_24_BIT + ";152;205;147" + ansi.SGR
        ORANGE   = ansi.CSI + ansi.FG_COLOR_24_BIT + ";214;152;38"  + ansi.SGR
        RED      = ansi.CSI + ansi.FG_COLOR_24_BIT + ";183;76;46"   + ansi.SGR
    } else {
        MAGENTA = ansi.CSI + ansi.FG_MAGENTA  + ansi.SGR    
        CYAN    = ansi.CSI + ansi.FG_CYAN     + ansi.SGR
        YELLOW  = ansi.CSI + ansi.FG_YELLOW   + ansi.SGR
        GREEN   = ansi.CSI + ansi.FG_GREEN    + ansi.SGR
        ORANGE  = ansi.CSI + ansi.FG_YELLOW   + ansi.SGR
        RED     = ansi.CSI + ansi.FG_RED      + ansi.SGR
    }
	
	color := RESET
	switch level {
	case .Debug:             color = MAGENTA
	case LOG_LEVEL_INBOUND:  color = CYAN
	case LOG_LEVEL_OUTBOUND: color = YELLOW
	case .Info:    color = GREEN
	case .Warning: color = ORANGE
	case .Error, .Fatal, LOG_LEVEL_REACTOR_ERROR: color = RED
	}
	
	if .Level in options {
	    if .Terminal_Color in options {
			fmt.sbprint(&header_sb, color)
		}
		fmt.sbprint(&header_sb, log.Level_Headers[level])
		if .Terminal_Color in options {
		    fmt.sbprint(&header_sb, RESET)
		}
	}
	
	if .Terminal_Color in options {
	    fmt.sbprint(&header_sb, GRAY)
	}
	subsystem := string(cstring(data))
	fmt.sbprintf(&header_sb, "(%s): ", subsystem)
	if .Terminal_Color in options {
	    fmt.sbprint(&header_sb, RESET)
	}
	
	fmt.fprintfln(handle, "%s%s", strings.to_string(header_sb), text)
}