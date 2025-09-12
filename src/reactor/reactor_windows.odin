package reactor

import "core:log"
import "core:mem"
import "core:net"
import "core:mem/tlsf"
import win32 "core:sys/windows"

import "lib:tracy"

_ :: tlsf

foreign import kernel32 "system:Kernel32.lib"

// TODO: change to win32 type after odin release dev-09
@(default_calling_convention="system", private="file")
foreign kernel32 {
    CancelIoEx :: proc(hFile: win32.HANDLE, lpOverlapped: win32.LPOVERLAPPED) -> win32.BOOL ---
    RtlNtStatusToDosError :: proc(status: win32.NTSTATUS) -> win32.ULONG ---
}

// only allow one concurrent io worker for now
@(private="file")
IOCP_CONCURRENT_THREADS :: 1

// required size to store ipv4 socket addr for AcceptEx calls (see docs)
@(private="file")
ADDR_BUF_SIZE :: size_of(win32.sockaddr_in) + 16

// how many bytes of actual data to receive into the AcceptEx buffer
@(private="file")
ACCEPTEX_RECEIVE_DATA_LENGTH :: 0

@(private="file")
USE_TLSF :: true

// both dynamically loaded by an WsaIoctl call
@(private="file")
_accept_ex := win32.LPFN_ACCEPTEX(nil)
@(private="file")
_accept_ex_sock_addrs := win32.LPFN_GETACCEPTEXSOCKADDRS(nil)

@(private)
_IOContext :: struct {
	completion_port: win32.HANDLE,
	server_sock: win32.SOCKET,
	// TODO: separate into two allocators, one for per client recv bufs/write bufs (maybe) and
	// one for completion entries, freelist block based, or perhaps even epoch based recycling (assuming no iocp stalls occur)
	allocator: mem.Allocator,

	// Client socket on which to accept connections (`AcceptEx` style).
	accepted_sock: win32.SOCKET,
	// Buf where local and remote addr are placed.
	accept_buf: [ADDR_BUF_SIZE * 2]u8,
}

@(private)
_create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: IOContext, ok: bool) {
    tracy.Zone()
    _lower_timer_resolution()

    ctx.completion_port = win32.CreateIoCompletionPort(
		win32.INVALID_HANDLE_VALUE,
		win32.HANDLE(nil),
		0, /* completion key (ignored) */
		IOCP_CONCURRENT_THREADS,
	)
	if ctx.completion_port == nil {
        _log_error(win32.GetLastError(), "failed to create IO completion port")
		return ctx, false
	}
	defer if !ok {
	    _ = win32.CloseHandle(ctx.completion_port)
	}

	ctx.server_sock = win32.SOCKET(server_sock)
	_accept_ex = _load_wsa_fn_ptr(&ctx, win32.WSAID_ACCEPTEX, win32.LPFN_ACCEPTEX)
	_accept_ex_sock_addrs = _load_wsa_fn_ptr(&ctx, win32.WSAID_GETACCEPTEXSOCKADDRS, win32.LPFN_GETACCEPTEXSOCKADDRS)

	if _accept_ex == nil || _accept_ex_sock_addrs == nil {
	    _log_error(win32.WSAGetLastError(), "failed to load WSA function pointers")
    	return ctx, false
	}

	when USE_TLSF {
	    tlsf_alloc := new(tlsf.Allocator, allocator)
		init_err := tlsf.init_from_allocator(
		    tlsf_alloc,
			backing=allocator,
			initial_pool_size=6 * RECV_BUF_SIZE,
			new_pool_size=120 * RECV_BUF_SIZE,
		)
		assert(init_err == .None, "failed to init tlsf allocator")
		ctx.allocator = tlsf.allocator(tlsf_alloc)
		defer if !ok {
		    tlsf.destroy(tlsf_alloc)
			free(tlsf_alloc, allocator)
		}
	} else {
    	arena := new(mem.Dynamic_Arena, allocator)
    	mem.dynamic_arena_init(
    		arena,
    		block_allocator=allocator,
    		array_allocator=allocator,
            block_size=120 * RECV_BUF_SIZE,
    	)
    	// TODO: individual frees are not supported, are we slowly leaking memory?
    	ctx.allocator = mem.dynamic_arena_allocator(arena)
    	defer if !ok {
    	    mem.dynamic_arena_destroy(arena)
    		free(arena, allocator)
    	}
	}

	_install_accept_handler(&ctx) or_return

	// allow server sock to emit iocp events (for accept() processing)
	result := win32.CreateIoCompletionPort(
	    win32.HANDLE(ctx.server_sock),
		ctx.completion_port,
		0,
		IOCP_CONCURRENT_THREADS,
	)
	if result != win32.HANDLE(ctx.server_sock) && win32.GetLastError() != win32.ERROR_IO_PENDING {
	    _log_error(win32.GetLastError(), "failed to register server socket to completion port")
	    return
	}

	return ctx, true
}

// Installs an `AcceptEx` handler to the context, which will emit IOCP events for inbound connections.
@(private="file")
_install_accept_handler :: proc(ctx: ^IOContext) -> bool {
    tracy.Zone()

	// socket that AcceptEx will use to bind the accepted client to
	ctx.accepted_sock = _create_accept_client_socket() or_return
	comp := _alloc_completion(ctx^, .Read, ctx.server_sock, {})

	// FIXME: we "know" clients will always send initial data after connecting (handshake packets and such),
	// can we specify a recv buffer length > 0, while also defending against denial of service attacks
	// by clients connecting and not sending data?
	accept_ok := _accept_ex(
		ctx.server_sock,
		ctx.accepted_sock,
		&ctx.accept_buf[0],
		ACCEPTEX_RECEIVE_DATA_LENGTH,
		ADDR_BUF_SIZE, /* local addr len */
		ADDR_BUF_SIZE, /* remote addr len */
		nil,           /* bytes received */
		&comp.overlapped,
	)
	// on ERROR_IO_PENDING, the operation was successfully initiated and is still in progress
	if accept_ok != win32.TRUE && win32.WSAGetLastError() != i32(win32.ERROR_IO_PENDING) {
	    _log_error(win32.WSAGetLastError(), "could not setup accept handler")
		return false
	}
	return true
}

// Create a socket implicitly configured for overlapping io.
@(private="file")
_create_accept_client_socket :: proc() -> (win32.SOCKET, bool) {
    sock := win32.socket(win32.AF_INET, win32.SOCK_STREAM, 0)
	if sock == win32.INVALID_SOCKET {
	    _log_error(win32.WSAGetLastError(), "could not preconfigure client socket")
		return sock, false
	}
	return sock, true
}

@(private)
_destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
	// NOTE: refcounted, no socket handles must be associated with this iocp
	win32.CloseHandle(ctx.completion_port)
	_ = win32.CloseHandle(win32.HANDLE(ctx.accepted_sock))

	when USE_TLSF {
	    tlsf_alloc := cast(^tlsf.Allocator) ctx.allocator.data
		tlsf.destroy(tlsf_alloc)
		free(tlsf_alloc, allocator)
	} else {
	    arena := cast(^mem.Dynamic_Arena) ctx.allocator.data
    	mem.dynamic_arena_destroy(arena)
    	free(arena, allocator)
	}
}

// Inputs:
// - `recv_buf`: a preallocated recv buffer which will be used for the whole lifetime of the connection.
@(private="file")
_register_client :: proc(ctx: ^IOContext, client: win32.SOCKET) -> bool {
    tracy.Zone()
    handle := win32.HANDLE(client)

    register_result := win32.CreateIoCompletionPort(
        handle,
        ctx.completion_port,
        0, /* completion key (unused) */
        IOCP_CONCURRENT_THREADS,
    )
    if register_result != ctx.completion_port {
        _log_error(win32.GetLastError(), "failed to register client to iocp")
        return false
    }

    // don't bother setting up OVERLAPPED.hEvent, we are using iocp for notifications, not WaitForSingleObject and related logic
    if !win32.SetFileCompletionNotificationModes(handle, win32.FILE_SKIP_SET_EVENT_ON_HANDLE) {
        _log_error(win32.GetLastError(), "failed to set FILE_SKIP_SET_EVENT bit")
    }

    return _initiate_recv(ctx, client)
}

// Initiate async recv call to emit an iocp event whenever data can be read
@(private="file")
_initiate_recv :: proc(ctx: ^IOContext, client: win32.SOCKET) -> bool {
    tracy.Zone()

    // alloc a new recv buffer per recv operation, we could in theory use two buffers per client
    // and rotate them, but a pool/slab allocator works good enough for this
    recv_buf: []u8
    {
        tracy.ZoneN("ALLOC_RECV")
        recv_buf = make([]u8, RECV_BUF_SIZE, ctx.allocator) or_else panic("OOM")
    }
    comp := _alloc_completion(ctx^, .Read, win32.SOCKET(client), recv_buf)

    flags: u32
	result := win32.WSARecv(
		win32.SOCKET(client),
		&win32.WSABUF { u32(len(recv_buf)), raw_data(recv_buf) },
		1,      /* buffer count */
		nil,    /* nr of bytes received */
		&flags,
		cast(win32.LPWSAOVERLAPPED) &comp.overlapped,
		nil,   /* completion routine */
	)
	if result != 0 && win32.WSAGetLastError() != i32(win32.ERROR_IO_PENDING) {
	    _log_error(win32.WSAGetLastError(), "failed to initiate WSARecv")
		return false
	}

	return true
}

@(private="file")
IOOperationData :: struct {
    overlapped: win32.OVERLAPPED,
    source: win32.SOCKET,
	// buffer for written or received data, in the case of partial writes, this always
	// contains the whole write buffer, and `write_already_transfered` is used to indicate
	// which part actually still needs to be transferred. (we must store the whole buffer to avoid leaking it)
	transport_buf: []u8 `fmt:"-"`,
	write_already_transfered: u32,
	op: IOOperation,
}

// IO operation as seen from our side.
@(private="file")
IOOperation :: enum u8 {
	Read,
	Write,
}

@(private)
_unregister_client :: proc(ctx: ^IOContext, client: net.TCP_Socket) -> bool {
    // cancel outstanding io operations, yet to arrive completions will have a ERROR_OPERATION_ABORTED status.
    // this is the only way to unregister clients, there is no real "iocp unregister" procedure
    ok := CancelIoEx(win32.HANDLE(win32.SOCKET(client)), /*cancel all*/ nil)

    // TODO: replace with proper ERROR_ constant after it's defined in win32 pkg (dev-10)
    if !ok && win32.GetLastError() != win32.DWORD(win32.System_Error.NOT_FOUND) {
        _log_error(win32.GetLastError(), "failed to cancel outstanding io operations")
    }
    net.close(client)
	return true
}

@(private)
_await_io_completions :: proc(ctx: ^IOContext, completions_out: []Completion, timeout_ms: int) -> (n: int, ok: bool) {
    tracy.Zone()
	completion_entries := make([]win32.OVERLAPPED_ENTRY, len(completions_out), context.temp_allocator)
	nready: u32

	{
	    tracy.ZoneN("GetQueuedCompletionStatusEx")

    	// we could in theory also do this with event handles or APCs
        // NOTE: nothing is guaranteed in terms of order, but we only have one concurrent read for each socket,
        // and potentially multiple writes, so this does not seem to be an issue
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
            _log_error(win32.GetLastError(), "failed to queue completion entries")
    		return
    	}
	}

	i := 0
	for entry in completion_entries[:nready] {
	    tracy.ZoneN("CompletionEntry")
		defer i += 1

		op_data: ^IOOperationData = container_of(entry.lpOverlapped, IOOperationData, "overlapped")
		#no_bounds_check comp := &completions_out[i]
  		comp.socket = net.TCP_Socket(op_data.source)

        // map NTSTATUS to win32 error
        status := RtlNtStatusToDosError(i32(entry.Internal))
        if status == u32(win32.ERROR_OPERATION_ABORTED) {
            tracy.ZoneN("Stale Completion")
            // incoming completion packet for already unregistered connection, ignore
            i -= 1 // reuse same entry
            nready -= 1
            continue
        } else if status != 0 {
            _log_error(status, "completion entry failed with error")
            comp.operation = .Error
			continue
        }

        comp.nr_of_bytes_affected = entry.dwNumberOfBytesTransferred

		switch op_data.op {
		case .Read:
			if op_data.source == ctx.server_sock {
			    // newly accepted client stored in io context
			    accept_success := false
				defer if !accept_success {
				    // TODO: what happens with this entry?
				    net.close(net.TCP_Socket(ctx.accepted_sock))
				}

				_configure_accepted_client(ctx) or_continue
				_register_client(ctx, ctx.accepted_sock) or_continue
				comp.operation = .NewConnection
				comp.socket = net.TCP_Socket(ctx.accepted_sock)
				accept_success = true

				// re-arm accept handler
				// TODO: consider this as being fatal, no more new clients can be accepted..
				_install_accept_handler(ctx) or_break
				continue
			}

			if entry.dwNumberOfBytesTransferred == 0 {
			    comp.operation = .PeerHangup
			} else {
    			comp.operation = .Read
    			comp.recv_buf = op_data.transport_buf[:entry.dwNumberOfBytesTransferred]

    			// re-arm recv handler
    			_initiate_recv(ctx, op_data.source) or_continue
			}
		case .Write:
		    total_transfer := entry.dwNumberOfBytesTransferred + op_data.write_already_transfered
		    partial_write := int(total_transfer) != len(op_data.transport_buf)
			if partial_write {
			    // ignore this entry, query another send with the remaining part of the buffer
				i -= 1
				nready -= 1

				_initiate_send(ctx, op_data.source, op_data.transport_buf, partial_write_off=total_transfer) or_continue
				continue
			}

		    comp.operation = .Write
			assert(int(entry.dwNumberOfBytesTransferred) == len(op_data.transport_buf), "partial writes should be handled above")
		}
	}

	return int(nready), true
}

// TODO: don't actually flush on every call
@(private)
_submit_write_copy :: proc(ctx: ^IOContext, client: net.TCP_Socket, data: []u8) -> bool {
    tracy.Zone()

    return _initiate_send(ctx, win32.SOCKET(client), data)
}

@(private="file")
_initiate_send :: proc(ctx: ^IOContext, client: win32.SOCKET, data: []u8, partial_write_off: u32 = 0) -> bool {
    comp := _alloc_completion(ctx^, .Write, client, data)
    comp.write_already_transfered = partial_write_off

    // handle potential partial writes, send this buffer while we keep storing the original in order to free it later
    data := data[partial_write_off:]
    // this returns WSAENOTSOCK when the socket is already closed
    result := win32.WSASend(
        comp.source,
        &win32.WSABUF { u32(len(data)), raw_data(data) },
        1, /* buffer count */
        nil,
        0, /* flags */
        cast(win32.LPWSAOVERLAPPED) &comp.overlapped,
        nil, /* completion routine */
    )
    if result != 0 && win32.WSAGetLastError() != i32(win32.ERROR_IO_PENDING) {
        _log_error(win32.WSAGetLastError(), "failed to initiate WSASend")
        return false
    }
    return true
}

// Accepts a new client on the server socket, and stores it in `ctx.accept_sock`.
@(private="file")
_configure_accepted_client :: proc(ctx: ^IOContext) -> bool {
    tracy.Zone()

    // parse AcceptEx buffer to find addresses (unused) and unblock socket
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

	// accepted socket is in the default state, update it to make
	// setsockopt among other functions work
	result := win32.setsockopt(
		ctx.accepted_sock,
        win32.SOL_SOCKET,
        win32.SO_UPDATE_ACCEPT_CONTEXT,
        &ctx.server_sock, size_of(ctx.server_sock),
	)
	if result != 0 {
	    return false
	}

	if net.set_blocking(net.TCP_Socket(ctx.accepted_sock), false) != .None {
	    return false
	}
	if net.set_option(net.TCP_Socket(ctx.accepted_sock), .TCP_Nodelay, true) != .None {
	    return false
	}
	return true
}

@(private="file")
_alloc_completion :: proc(ctx: IOContext, op: IOOperation, source: win32.SOCKET, buf: []u8) -> ^IOOperationData {
    comp := new(IOOperationData, ctx.allocator)
    comp.op = op
    comp.source = source
    comp.transport_buf = buf

    return comp
}

// Alters timer resolution, in order to obtain millisecond precision for the event loop (if possible).
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

@(private="file")
_log_error :: proc(#any_int err: win32.DWORD, message: string) {
    log.logf(ERROR_LOG_LEVEL, "%s: %s", message, win32.System_Error(err))
}