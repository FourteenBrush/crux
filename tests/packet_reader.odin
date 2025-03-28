package test

import "core:slice"
import "core:testing"
import "core:math/rand"

import crux "../src"

// TODO: add tests to read data when nothing is present

@(private)
expect_same_retrieval :: proc(t: ^testing.T, buf: ^crux.NetworkBuffer, data: ^[$S]u8) {
    retrieved, ok := crux.read_nbytes(buf, len(data))
    testing.expect(t, ok)
    testing.expectf(t, slice.equal(data[:], retrieved), "expected data to be equal: %v and %v differ", data, retrieved)
}

@(test)
test_length_and_offset_correctness :: proc(t: ^testing.T) {
    using crux
    r := create_network_buffer()
    defer destroy_network_buf(&r)

    data := random_block(50)
    push_data(&r, data[:])

    testing.expect(t, r.len == len(data))
    testing.expect(t, r.r_offset == 0)

    expect_same_retrieval(t, &r, &data)
}

@(test)
test_packed_reads_zero_offset :: proc(t: ^testing.T) {
    using crux
    r := create_network_buffer()
    defer destroy_network_buf(&r)

    data := random_block(50)
    push_data(&r, data[:])

    expect_same_retrieval(t, &r, &data)
}

// write 20 bytes, then 50, read the 20 back out and assure next read returns 50, subsequent reads fail
@(test)
test_packed_read_non_enclosed_block :: proc(t: ^testing.T) {
    using crux
    r := create_network_buffer()
    defer destroy_network_buf(&r)

    b20 := random_block(20)
    b50 := random_block(50)

    push_data(&r, b20[:])
    push_data(&r, b50[:])

    retrieved20, _ := read_nbytes(&r, len(b20))
    testing.expect(t, slice.equal(b20[:], retrieved20))

    retrieved50, _ := read_nbytes(&r, len(b50))
    testing.expect(t, slice.equal(b50[:], retrieved50))

    bytes, ok := read_nbytes(&r, 1)
    testing.expect_value(t, len(bytes), 0)
    testing.expect(t, !ok, "expected next read to fail as buf is empty")
}

@(test)
test_growth :: proc(t: ^testing.T) {
    using crux
    r := create_network_buffer(cap=50)
    defer destroy_network_buf(&r)

    data := random_block(50)
    push_data(&r, data[:])
    testing.expect(t, r.len == len(data))
    testing.expect(t, r.r_offset == 0)
    testing.expect(t, cap(r.data) == 50)
}

@(test)
read_on_empty :: proc(t: ^testing.T) {
    using crux
    r := create_network_buffer()
    defer destroy_network_buf(&r)

    bytes, ok := read_nbytes(&r, 1)
    testing.expect_value(t, len(bytes), 0)
    testing.expect(t, !ok, "expected read to fail as buf is empty")
}

@(private)
random_block :: proc($Size: int) -> (b: [Size]u8) {
    _ = rand.read(b[:])
    return
}
