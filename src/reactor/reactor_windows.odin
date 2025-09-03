package reactor

import "core:os"
import "core:mem"
import "core:net"
import win32 "core:sys/windows"

import "lib:tracy"

// only allow one concurrent io worker for now
@(private="file")
IOCP_CONCURRENT_THREADS :: 1

// required size to store ipv6 socket addr for AcceptEx calls (see docs)
@(private="file")
ADDR_BUF_SIZE :: size_of(win32.sockaddr_in) + 16

// how many bytes of data to receive into the AcceptEx buffer
@(private="file")
ACCEPTEX_RECEIVE_DATA_LENGTH :: 0

// fn ptr signature for `GetAcceptExSockaddrs`
// TODO: change to win32 type after tagged odin release dev-09
@(private="file")
LPFN_GETACCEPTEXSOCKADDRS :: #type proc "system" (
	lpOutputBuffer:        win32.PVOID,
	dwReceiveDataLength:   win32.DWORD,
	dwLocalAddressLength:  win32.DWORD,
	dwRemoteAddressLength: win32.DWORD,
	LocalSockaddr:         ^^win32.sockaddr,
	LocalSockaddrLength:   win32.LPINT,
	RemoteSockaddr:        ^^win32.sockaddr,
	RemoteSockaddrLength:  win32.LPINT,
)

// both dynamically loaded by an WsaIoctl call
@(private="file")
_accept_ex := win32.LPFN_ACCEPTEX(nil)
@(private="file")
_accept_ex_sock_addrs := LPFN_GETACCEPTEXSOCKADDRS(nil)

_IOContext :: struct {
	completion_port: win32.HANDLE,
	server_sock: win32.SOCKET,
	connections: map[win32.SOCKET]ClientData,
	arena: ^mem.Dynamic_Arena,
	arena_allocator: mem.Allocator,

	// Client socket on which to accept connections (`AcceptEx` style).
	accept_sock: win32.SOCKET,
	// Buf where local and remote addr are placed.
	accept_buf: [ADDR_BUF_SIZE * 2]u8,
}

@(private)
ClientData :: struct {
}

// TODO: use net._dial_error()

// TODO: cleanup here on partial failures
_create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: IOContext, ok: bool) {
    _lower_timer_resolution()

    ctx.completion_port = win32.CreateIoCompletionPort(
		win32.INVALID_HANDLE_VALUE,
		win32.HANDLE(nil),
		0, /* completion key (ignored) */
		IOCP_CONCURRENT_THREADS,
	)
	if ctx.completion_port == nil {
	    os.print_error(os.stderr, win32.System_Error(win32.GetLastError()), "failed to create iocp")
		return ctx, false
	}

	ctx.server_sock = win32.SOCKET(server_sock)
	_accept_ex = _load_wsa_fn_ptr(&ctx, win32.WSAID_ACCEPTEX, win32.LPFN_ACCEPTEX)
	_accept_ex_sock_addrs = _load_wsa_fn_ptr(&ctx, win32.WSAID_GETACCEPTEXSOCKADDRS, LPFN_GETACCEPTEXSOCKADDRS)

	if _accept_ex == nil || _accept_ex_sock_addrs == nil {
        os.print_error(os.stderr, win32.System_Error(win32.WSAGetLastError()), "failed to load WSA function pointers")
    	return ctx, false
	}

	ctx.arena = new(mem.Dynamic_Arena, allocator)
	mem.dynamic_arena_init(
		ctx.arena,
		block_allocator=allocator,
		array_allocator=allocator,
	)
	// TODO: individual frees are not supported, are we slowly leaking memory?
	ctx.arena_allocator = mem.dynamic_arena_allocator(ctx.arena)

	_install_accept_handler(&ctx) or_return

	// allow server sock to emit iocp events (for accept() processing)
	result := win32.CreateIoCompletionPort(
	    win32.HANDLE(ctx.server_sock),
		ctx.completion_port,
		0,
		IOCP_CONCURRENT_THREADS,
	)
	if result != win32.HANDLE(ctx.server_sock) && win32.GetLastError() != win32.ERROR_IO_PENDING {
	    os.print_error(os.stderr, win32.System_Error(win32.GetLastError()), "failed to register server sock")
	    return
	}

	ctx.connections = make(map[win32.SOCKET]ClientData, 16, ctx.arena_allocator)

	return ctx, true
}

// Installs an `AcceptEx` handler to the context, which will emit IOCP events for inbound connections.
@(private="file")
_install_accept_handler :: proc(ctx: ^IOContext) -> bool {
    comp := new(Completion, ctx.arena_allocator)
    comp.client = ctx.server_sock

	// socket that AcceptEx will use to bind the accepted client to
	ctx.accept_sock = _create_accept_client_socket() or_return

	// FIXME: we "know" clients will always send initial data after connecting (handshake packets and such),
	// can we specify a recv buffer length > 0, while also defending against denial of service attacks
	// by clients connecting and not sending data?
	accept_ok := _accept_ex(
		ctx.server_sock,
		ctx.accept_sock,
		&ctx.accept_buf[0],
		ACCEPTEX_RECEIVE_DATA_LENGTH,
		ADDR_BUF_SIZE, /* local addr len */
		ADDR_BUF_SIZE, /* remote addr len */
		nil,           /* bytes received */
		&comp.overlapped,
	)
	// on ERROR_IO_PENDING, the operation was successfully initiated and is still in progress
	if accept_ok != win32.TRUE && win32.WSAGetLastError() != i32(win32.ERROR_IO_PENDING) {
        os.print_error(os.stderr, win32.System_Error(win32.WSAGetLastError()), "could not setup accept() handler")
		return false
	}
	return true
}

// Create a socket implicitly configured for overlapping io.
@(private="file")
_create_accept_client_socket :: proc() -> (win32.SOCKET, bool) {
    sock := win32.socket(win32.AF_INET, win32.SOCK_STREAM, 0)
	if sock == win32.INVALID_SOCKET {
        os.print_error(os.stderr, win32.System_Error(win32.WSAGetLastError()), "could not preconfigure client socket")
		return sock, false
	}
	return sock, true
}

_destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
	// NOTE: refcounted, no handles must be associated
	win32.CloseHandle(ctx.completion_port)
	delete(ctx.connections)
	mem.dynamic_arena_destroy(ctx.arena)
	free(ctx.arena, allocator)
	// TODO: some CancelIoEx here, after ensuring iocp binds to server socket?
}

_register_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    register_result := win32.CreateIoCompletionPort(
        win32.HANDLE(uintptr(client)),
        ctx.completion_port,
        0, /* completion key (unused) */
        IOCP_CONCURRENT_THREADS,
    )
    if register_result != ctx.completion_port {
        os.print_error(os.stderr, win32.System_Error(win32.GetLastError()), "failed to register client to iocp")
        return false
    }

    // TODO: instead of looking up info via ^OVERLAPPED, pass this ptr in the completion key?
	data := new(Completion, ctx.arena_allocator)
	data.client = win32.SOCKET(client)
	buf := make([]u8, REACTOR_RECV_BUF_SIZE, ctx.arena_allocator)
	data.buf = win32.WSABUF {
		u32(len(buf)),
		raw_data(buf),
	}

	// initiate async recv call to emit iocp events whenever data is available
	flags: u32
	result := win32.WSARecv(
		win32.SOCKET(client),
		&data.buf,
		1,      /* buffer count */
		nil,    /* nr of bytes received */
		&flags,
		cast(win32.LPWSAOVERLAPPED) &data.overlapped,
		nil, /* completion routine */
	)
	if result != 0 && win32.WSAGetLastError() != i32(win32.ERROR_IO_PENDING) {
	    os.print_error(os.stderr, win32.System_Error(win32.WSAGetLastError()), "failed to initiate WSARecv")
		return false
	}

	return true
}

@(private="file")
Completion :: struct {
	op: IOOperation,
	client: win32.SOCKET,
	buf: win32.WSABUF,
	overlapped: win32.OVERLAPPED,
}

IOOperation :: enum {
	Read,
	Write,
}

_unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
	return true
}

_await_io_events :: proc(ctx: ^IOContext, events_out: []Event, timeout_ms: int) -> (n: int, ok: bool) {
    tracy.Zone()
	completion_entries := make([]win32.OVERLAPPED_ENTRY, len(events_out), context.temp_allocator)
	nready: u32

	{
	    tracy.ZoneN("GetQueuedCompletionStatusEx")

    	// we could in theory also do this with event handles or APCs
    	result := win32.GetQueuedCompletionStatusEx(
    		ctx.completion_port,
    		raw_data(completion_entries),
    		u32(len(completion_entries)),
    		&nready,
    		u32(timeout_ms),
    		fAlertable=win32.FALSE,
    	)
    	// instead of returning TRUE, 0, WAIT_TIMEOUT is being set
    	if result == win32.FALSE && win32.GetLastError() != win32.WAIT_TIMEOUT {
    	    os.print_error(os.stderr, win32.System_Error(win32.GetLastError()), "queuing completion entries failed")
    		return
    	}
	}

	for entry, i in completion_entries[:nready] {
	    tracy.ZoneN("CompletionEntry")

		io_succeeded := entry.Internal == 0
		if !io_succeeded {
			events_out[i].flags = {.Err}
			continue
		}

		completion: ^Completion = container_of(entry.lpOverlapped, Completion, "overlapped")
		events_out[i].client = net.TCP_Socket(completion.client)

		switch completion.op {
		case .Read:
		    events_out[i].flags = {.Readable}

			if completion.client == ctx.server_sock {
			    tracy.ZoneN("AcceptEx")
			    events_out[i].flags += {.ServerSockEmitted}
				events_out[i].client = net.TCP_Socket(ctx.accept_sock)

			    // new connection, parse AcceptEx buffer to find addresses (unused)
				local_addr: ^win32.sockaddr
				local_addr_len: i32
				remote_addr: ^win32.sockaddr
				remote_addr_len: i32
				_accept_ex_sock_addrs(
				    &ctx.accept_buf[0],
					ACCEPTEX_RECEIVE_DATA_LENGTH,
					ADDR_BUF_SIZE,
					ADDR_BUF_SIZE,
					&local_addr,
					&local_addr_len,
					&remote_addr,
					&remote_addr_len,
				)

				// accepted socket is in the default state, update it
				result := win32.setsockopt(
    				ctx.accept_sock,
                    win32.SOL_SOCKET,
                    win32.SO_UPDATE_ACCEPT_CONTEXT,
                    &ctx.server_sock, size_of(ctx.server_sock),
				)
				if result != 0 {
				    events_out[i].flags = {.Err}
					continue
				}
				assert(net.set_blocking(net.TCP_Socket(ctx.accept_sock), false) == .None)
				_register_client(ctx, net.TCP_Socket(ctx.accept_sock)) or_continue

				// re-arm accept handler
				_install_accept_handler(ctx) or_break
			}
		case .Write:
		    events_out[i].flags = {.Writable}
		}

		// TODO: put error in event?
	}

	return int(nready), true
}

// Changes timer resolution, in order to obtain millisecond precision for the event loop (if possible).
@(private="file")
_lower_timer_resolution :: proc() {
    caps: win32.TIMECAPS
    res := win32.timeGetDevCaps(&caps, size_of(caps))
    assert(res == win32.MMSYSERR_NOERROR, "failed querying timer resolution")
    res = win32.timeBeginPeriod(max(1, caps.wPeriodMin))
    assert(res == win32.MMSYSERR_NOERROR, "failed changing timer resolution")
}

// Dynamically loads a WSA function pointer, returns `nil` on failure.
@(private="file")
_load_wsa_fn_ptr :: proc(ctx: ^IOContext, guid: win32.GUID, $Sig: typeid) -> (fn_ptr: Sig) {
    assert(ctx.server_sock != 0)
    guid := guid
    nbytes: u32

    result := win32.WSAIoctl(
        ctx.server_sock,
        win32.SIO_GET_EXTENSION_FUNCTION_POINTER,
        &guid,
        size_of(guid),
        &fn_ptr,
        size_of(fn_ptr),
        &nbytes,
        nil, /* overlapped */
        nil, /* completion routine */
    )

    if result == win32.SOCKET_ERROR {
        return nil
    }
    assert(nbytes == size_of(fn_ptr))
    return
}
