package test

import "core:fmt"
import "core:net"
import "core:time"
import "core:thread"
import "core:testing"

import "../src/reactor"

@(private="file")
RECV_BUF_SIZE :: 2048

// FIXME: this actually causes a partial write, currently only one completion packet seems to arrive internally
@(test)
partial_write_arrives_in_one_completion :: proc(t: ^testing.T) {
    _endpoint := net.Endpoint { address = net.IP4_Loopback, port = 0 /* make os choose free port */ }
    server_sock, listen_err := net.listen_tcp(_endpoint)
    defer if listen_err != nil {
        net.close(server_sock)
    }
    if !testing.expect_value(t, listen_err, nil) {
        return
    }

    // figure out the actual port we bound to
    endpoint, info_err := net.bound_endpoint(server_sock)
    if !testing.expect(t, info_err == .None, "failed to query bound endpoint") {
        return
    }

    // spawn client
    client_data := ClientData {
        server_endpoint = endpoint,
    }
    thread.create_and_start_with_poly_data(&client_data, _client_entry, init_context=context, self_cleanup=true)

    context.logger.lowest_level = reactor.ERROR_LOG_LEVEL
    io, creation_ok := reactor.create_io_context(server_sock, context.allocator)
    if !testing.expect(t, creation_ok, "failed to create io context") {
        return
    }
    defer if creation_ok {
        reactor.destroy_io_context(&io, context.allocator)
    }

    // perform chunked write, confirm only one write completion arrives
    client_state: enum { AwaitingConn, Idle, ReceivedWrite, ReceivedHangup } = .AwaitingConn

    thread: for {
        events: [128]reactor.Event
        nready, ok := reactor.await_io_events(&io, events[:], timeout_ms=5)
        testing.expect(t, ok, "failed to await io events") or_break thread

        for event in events[:nready] {
            testing.expect(t, .Error not_in event.operations, "event with .Error flag was returned") or_break thread
            testing.expect(t, .Read not_in event.operations, "unexpected .Read event")

            if .NewConnection in event.operations {
                testing.expectf(t, client_state == .AwaitingConn, "received .NewConnection event in state %s", client_state) or_break thread
                client_state = .Idle

                // shrink send buffer to achieve partial writes
                opt_err := net.set_option(server_sock, .Send_Buffer_Size, RECV_BUF_SIZE)
                testing.expect(t, opt_err == nil, "failed to configure send buffer size") or_break thread

                data := make([]u8, RECV_BUF_SIZE * 3, context.temp_allocator)
                submission_ok := reactor.submit_write_copy(&io, event.socket, data)
                testing.expect(t, submission_ok, "failed to submit chunked write to client") or_break thread
            }
            if .Write in event.operations {
                testing.expectf(t, client_state == .Idle, "received .Write event in state %s", client_state) or_break thread
                client_state = .ReceivedWrite
            }
            if .Hangup in event.operations {
                testing.expectf(t, client_state == .ReceivedWrite, "received .Hangup event in state %s", client_state) or_break thread
                client_state = .ReceivedHangup
                break thread
            }
        }

        time.sleep(10 * time.Millisecond)
    }
}

@(private="file")
ClientData :: struct {
    server_endpoint: net.Endpoint,
}

@(private="file")
_client_entry :: proc(data: ^ClientData) {
    // connect to server
    server_sock, dial_err := net.dial_tcp_from_endpoint(data.server_endpoint)
    // should in theory use testing.except here but that's not threadsafe
    // this is all local traffic so shouldnt really have issues
    fmt.assertf(dial_err == nil, "failed to connect to server:", dial_err)
    defer if dial_err != nil {
        net.close(server_sock)
    }

    berr := net.set_blocking(server_sock, false)
    fmt.assertf(berr == .None, "failed to configure server socket to non blocking:", berr)

    // wait a bit to give server time to flush write
    time.sleep(50 * time.Millisecond)

    // size doesnt really matter here, we just need to make sure the server receives an eof
    recv_buf: [1024]u8
    for {
        n, recv_err := net.recv_tcp(server_sock, recv_buf[:])
        assert(recv_err == .None || recv_err == .Would_Block, "recv() failed")
        if n == 0 || recv_err == .Would_Block do break
    }
    net.close(server_sock)
}