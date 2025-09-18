#+build windows
package test

import "core:net"
import "core:time"
import "core:testing"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

// TODO: change to win32 type after odin release dev-10
@(default_calling_convention="system", private="file")
foreign kernel32 {
    CancelIoEx :: proc(hFile: win32.HANDLE, lpOverlapped: win32.LPOVERLAPPED) -> win32.BOOL ---
    RtlNtStatusToDosError :: proc(status: win32.NTSTATUS) -> win32.ULONG ---
}

// Ensure an CancelIoEx call on an initiated WSARecv collects
// an aborted completion through GetQueuedCompletionStatusEx
@(test)
cancelation_emits_abort_completion :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 5 * time.Second)

    // initialize server socket
    server_sock, listen_err := net.listen_tcp(net.Endpoint { address = net.IP4_Loopback })
    if !testing.expect(t, listen_err == nil) do return
    server_endp, info_err := net.bound_endpoint(net.TCP_Socket(server_sock))
    if !testing.expect(t, info_err == .None) do return
    defer net.close(server_sock)

    // create completion port
    iocp := win32.CreateIoCompletionPort(win32.INVALID_HANDLE_VALUE, win32.HANDLE(nil), 0, 1)
    if !testing.expect(t, iocp != win32.INVALID_HANDLE_VALUE, "failed to create iocp") do return
    defer win32.CloseHandle(iocp)

    // connect client and configure as non-blocking
    client_sock, dial_err := net.dial_tcp_from_endpoint(server_endp)
    if !testing.expect(t, dial_err == nil, "failed to connect client to server") do return
    set_blocking_err := net.set_blocking(net.TCP_Socket(client_sock), false)
    if !testing.expect(t, set_blocking_err == .None, "failed to configure client socket as non-blocking") do return
    defer net.close(client_sock)

    // associate iocp to client socket
    port := win32.CreateIoCompletionPort(win32.HANDLE(uintptr(client_sock)), iocp, 0, 1)
    if !testing.expect(t, port == iocp, "failed to associate iocp to client socket") do return

    // initiate async recv call, which should emit iocp completion once it completes or is canceled
    buf: [2]u8
    wsabuf := win32.WSABUF { u32(len(buf)), &buf[0] }
    flags: u32
    overlapped: win32.OVERLAPPED
    result := win32.WSARecv(win32.SOCKET(client_sock), &wsabuf, 1, nil, &flags, cast(win32.LPWSAOVERLAPPED) &overlapped, nil)
    if !testing.expect(t, result != 0, "expected != 0 result for WSARecv") do return
    if !testing.expect_value(t, win32.System_Error(win32.WSAGetLastError()), win32.System_Error.IO_PENDING) do return

    entries: [5]win32.OVERLAPPED_ENTRY
    n, poll_ok := poll_iocp(t, iocp, &entries)
    if !testing.expect(t, n == 0 && poll_ok, "no completions were expected") do return

    // cancel outstanding io operations and expect a completion packet indicating exactly that
    cancel_result := CancelIoEx(win32.HANDLE(uintptr(client_sock)), /* cancel everything from client */nil)
    if !testing.expect(
        t,
        cancel_result == win32.TRUE || win32.GetLastError() != win32.DWORD(win32.System_Error.NOT_FOUND),
        "CancelIoEx failed to find outstanding IO operations",
    ) {
        return
    }

    // poll for iocp completions and ensure a completion arrives with status OPERATION_ABORTED
    n, poll_ok = poll_iocp(t, iocp, &entries)
    if !testing.expect(t, n == 1 && poll_ok, "expected an aborted completion") do return

    entry_status := RtlNtStatusToDosError(win32.NTSTATUS(entries[0].Internal))
    if !testing.expect_value(t, win32.System_Error(entry_status), win32.System_Error.OPERATION_ABORTED) do return
}

// ensure we can free an OVERLAPPED structure right after a CancelIoEx call, ensuring polling
// does not break.
// FIXME: the docs say "the application must not free or reuse it until the operations have completed",
// might depend on the driver then
@(test)
free_overlapped_after_cancel_io :: proc(t: ^testing.T) {
    server_sock, server_err := net.listen_tcp(net.Endpoint { net.IP4_Loopback, 0 })
    if !testing.expect(t, server_err == nil, "failed to create server sock") do return
    bound_endpoint, info_err := net.bound_endpoint(server_sock)
    if !testing.expect(t, info_err == .None) do return

    iocp := win32.CreateIoCompletionPort(win32.INVALID_HANDLE_VALUE, win32.HANDLE(nil), 0, 1)
    if !testing.expect(t, iocp != win32.INVALID_HANDLE_VALUE, "failed to create iocp") do return
    defer win32.CloseHandle(iocp)

    // create client socket and connect to server sock
    client_sock, client_err := net.dial_tcp_from_endpoint(bound_endpoint)
    if !testing.expect(t, client_err == nil) do return
    defer net.close(client_sock)

    // associate socket with iocp
    port := win32.CreateIoCompletionPort(win32.HANDLE(uintptr(client_sock)), iocp, 0, 1)
    if !testing.expect(t, port == iocp, "failed to associate client with ioc") do return

    // initiate WSARecv with allocated OVERLAPPED
    buf: [2]u8
    flags: u32
    overlapped := new(win32.OVERLAPPED)
    res := win32.WSARecv(win32.SOCKET(client_sock), &win32.WSABUF { u32(len(buf)), &buf[0] }, 1, nil, &flags, cast(win32.LPWSAOVERLAPPED) overlapped, nil)
    if res != 0 && !testing.expect_value(t, win32.System_Error(win32.WSAGetLastError()), win32.System_Error.IO_PENDING) {
        return
    }

    // cancel io and poll iocp to make sure it arrives with OPERATION_ABORTED
    cancel_ok := CancelIoEx(win32.HANDLE(uintptr(client_sock)), overlapped) // works with nil too
    if !cancel_ok && !testing.expect_value(t, win32.System_Error(win32.GetLastError()), win32.System_Error.SUCCESS) do return

    free(overlapped)

    entries: [5]win32.OVERLAPPED_ENTRY
    n, poll_ok := poll_iocp(t, iocp, &entries)
    if !testing.expect(t, poll_ok, "failed to poll iocp") || !testing.expect_value(t, n, 1) do return

    testing.expect_value(t, win32.System_Error(RtlNtStatusToDosError(win32.NTSTATUS(entries[0].Internal))), win32.System_Error.OPERATION_ABORTED)
    testing.expect(t, entries[0].lpOverlapped == overlapped)
}

@(private="file")
poll_iocp :: proc(t: ^testing.T, iocp: win32.HANDLE, entries_out: ^[$N]win32.OVERLAPPED_ENTRY) -> (n: u32, ok: bool) {
    result := win32.GetQueuedCompletionStatusEx(iocp, &entries_out[0], u32(len(entries_out)), &n, 5, false)
    return n, testing.expect(t, result == win32.TRUE || win32.GetLastError() == win32.WAIT_TIMEOUT)
}