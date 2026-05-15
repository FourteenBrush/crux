#+feature using-stmt
package test

import "core:testing"
@(require) import "core:sys/posix"

import crux "../src"

PANIC_SIGNAL :: posix.SIGTRAP when ODIN_OS == .Darwin else posix.SIGILL

@(test)
write_scalar_at_root :: proc(t: ^testing.T) {
    using crux, testing
    buf := _new_buf()
    writer := NBTWriter { buf=&buf }
    
    expect_value(t,
        nbt_write_string(&writer, "this works"),
        WriteError.None,
    )
}

@(test)
write_multiple_root_elements :: proc(t: ^testing.T) {
    using crux, testing
    buf := _new_buf()
    writer := NBTWriter { buf=&buf }
    
    expect_value(t, nbt_write_string(&writer, "element 1"), WriteError.None)
    expect_value(t, nbt_write_string(&writer, "element 2"), WriteError.None)
    nbt_write_bool(&writer, true)
}

@(test)
write_named_scalar_at_root_should_fail :: proc(t: ^testing.T) {
    using crux, testing
    buf := _new_buf()
    writer := NBTWriter { buf=&buf }
    
    expect_signal(t, PANIC_SIGNAL)
    // should panic as soon as write_named_ is called
    expect_value(t,
        nbt_write_named_bool(&writer, "some-bool", true),
        WriteError.None,
    )
    fail_now(t, "write_named_ inside root should have failed")
}

@(private="file")
_new_buf :: proc() -> crux.NetworkBuffer {
    return crux.create_network_buf(allocator=context.temp_allocator)
}