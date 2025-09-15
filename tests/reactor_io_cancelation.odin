package test

import "core:net"
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
@(test, disabled=ODIN_OS != .Windows)
io_cancelation :: proc(t: ^testing.T) {
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
    if !testing.expect_value(t, entry_status, win32.ERROR_OPERATION_ABORTED) do return
}

poll_iocp :: proc(t: ^testing.T, iocp: win32.HANDLE, entries_out: ^[$N]win32.OVERLAPPED_ENTRY) -> (n: u32, ok: bool) {
    result := win32.GetQueuedCompletionStatusEx(iocp, &entries_out[0], u32(len(entries_out)), &n, 5, win32.FALSE)
    return n, testing.expect(t, result == win32.TRUE || win32.GetLastError() == win32.WAIT_TIMEOUT)
}