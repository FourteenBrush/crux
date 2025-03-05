package test

import "core:log"
import "core:testing"
import "core:container/queue"

import crux "../src"

Data :: struct($Size: uint) {
    data: [Size]u8,
}

@(test)
test_packed_reads_zero_offset :: proc(t: ^testing.T) {
    using crux
    r := create_packet_reader()
    defer destroy_packet_reader(&r)

    data := Data(50) {5}
    push_data(&r, data.data[:])
    retrieved, ok := read_packed(&r, type_of(data))
    testing.expect(t, ok)
    testing.expect_value(t, retrieved, data)
}

// write 20 bytes, then 50, read the 20 back out and assure next read returns 50, subsequent reads fail
@(test)
test_packed_read_non_enclosed_block :: proc(t: ^testing.T) {
    using crux
    r := create_packet_reader()
    defer destroy_packet_reader(&r)

    block20 := Data(20) {8}
    block50 := Data(50) {2}

    push_data(&r, block20.data[:])
    push_data(&r, block50.data[:])

    retrieved20, _ := read_packed(&r, type_of(block20))
    testing.expect_value(t, retrieved20, block20)

    retrieved50, _ := read_packed(&r, type_of(block50))
    testing.expect_value(t, retrieved50, block50)

    error, ok := read_packed(&r, Data(1)) // something non ZST
    testing.expectf(t, !ok, "expected next read to fail as buf is empty, len(buf): %d", queue.len(r.buf))
    testing.expect(t, !ok, "expected next read to fail as buf is empty")
    testing.expect_value(t, error, Data(1){})
}
