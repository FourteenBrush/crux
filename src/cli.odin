package crux

import "core:os"
import "core:log"
import "core:net"
import "core:flags"

CliArgs :: struct {
    endpoint: string,
}

parse_cli_args :: proc(allocator := context.allocator) -> (CliArgs, bool) {
    flags.register_flag_checker(endpoint_flag_checker)

    args: CliArgs
    if err := flags.parse(&args, os.args[1:], allocator=allocator); err != nil {
        log.error("failed to parse command line:", err)
        return args, false
    }

    return args, true
}

@(private="file")
endpoint_flag_checker :: proc(model: rawptr, name: string, value: any, args_tag: string) -> (err: string) {
    if name == "endpoint" {
        _, ok := net.parse_endpoint(value.(string))
        if !ok {
            return "invalid endpoint passed, requires the format <ip>[:port]"
        }
    }
    return
}
