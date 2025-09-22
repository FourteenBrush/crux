package reactor

import "core:log"
import "core:mem"
import "core:net"
import "core:mem/tlsf"
import win32 "core:sys/windows"

import "lib:back"
import "lib:tracy"

_ :: tlsf
_ :: back

foreign import kernel32 "system:Kernel32.lib"

// TODO: change to win32 type after odin release dev-10
@(default_calling_convention="system", private="file")
foreign kernel32 {
    CancelIoEx :: proc(hFile: win32.HANDLE, lpOverlapped: win32.LPOVERLAPPED) -> win32.BOOL ---
    RtlNtStatusToDosError :: proc(status: win32.NTSTATUS) -> win32.ULONG ---
}

// Only allow one concurrent io worker for now
@(private="file")
IOCP_CONCURRENT_THREADS :: 1

// Required size to store ipv4 socket addr for AcceptEx calls (see docs)
@(private="file")
ADDR_BUF_SIZE :: size_of(win32.sockaddr_in) + 16

// How many bytes of actual data to receive into the AcceptEx buffer
@(private="file")
ACCEPTEX_RECEIVE_DATA_LENGTH :: 0

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

	// Operation data of accept handler that never completed, needs to be deallocated when destroying ctx.
	last_accept_op_data: ^IOOperationData,
	// Buf where local and remote addr are placed on an accept call.
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
	when ODIN_DEBUG && !tracy.TRACY_ENABLE && !ODIN_TEST {
	    tracking_alloc := new(back.Tracking_Allocator, allocator)
		back.tracking_allocator_init(
		    tracking_alloc,
		    backing_allocator=allocator,
			internals_allocator=allocator,
		)
		ctx.allocator = back.tracking_allocator(tracking_alloc)
	}
	when tracy.TRACY_ENABLE {
	    ctx.allocator = tracy.MakeProfiledAllocator(
			new(tracy.ProfiledAllocatorData, allocator),
			callstack_size=14,
			backing_allocator=ctx.allocator,
		)
	}

	_install_accept_handler(&ctx) or_return

	// allow server sock to emit iocp notifications for new connections
	result := win32.CreateIoCompletionPort(
	    win32.HANDLE(ctx.server_sock),
		ctx.completion_port,
		win32.ULONG_PTR(ctx.server_sock),
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

    // socket that AcceptEx will use to bind the accepted client to,
    // implicitly configured for overlapped IO
    // TODO: close on cancellation
    client_sock := win32.socket(win32.AF_INET, win32.SOCK_STREAM, win32.IPPROTO_TCP)
	if client_sock == win32.INVALID_SOCKET {
	    _log_error(win32.WSAGetLastError(), "could not create client socket")
		return false
	}

	assert(ctx.last_accept_op_data == nil)
	op_data := _alloc_operation_data(ctx^, .AcceptedConnection, ctx.server_sock, {})
	op_data.accepted_conn.socket = client_sock
	ctx.last_accept_op_data = op_data

	// FIXME: we "know" clients will always send initial data after connecting (handshake packets and such),
	// can we specify a recv buffer length > 0, while also defending against denial of service attacks
	// by clients connecting and not sending data? (probably something with SO_CONNECT_TIME)
	accept_ok := _accept_ex(
		ctx.server_sock,
		client_sock,
		&ctx.accept_buf[0],
		ACCEPTEX_RECEIVE_DATA_LENGTH,
		ADDR_BUF_SIZE, /* local addr len */
		ADDR_BUF_SIZE, /* remote addr len */
		nil,           /* bytes received */
		&op_data.overlapped,
	)
	// on ERROR_IO_PENDING, the operation was successfully initiated and is still in progress
	if !accept_ok && win32.System_Error(win32.WSAGetLastError()) != .IO_PENDING {
	    _log_error(win32.WSAGetLastError(), "could not setup accept handler")
	    free(op_data, ctx.allocator)
		ctx.last_accept_op_data = nil
		return false
	}
	return true
}

@(private)
_destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    // cancel AcceptEx call
    overlapped := &ctx.last_accept_op_data.overlapped if ctx.last_accept_op_data != nil else nil
    _ = CancelIoEx(win32.HANDLE(ctx.server_sock), overlapped)

	// NOTE: refcounted, no socket handles must be associated with this iocp
	// TODO: close server socket here?
	win32.CloseHandle(ctx.completion_port)
	ctx.completion_port = win32.INVALID_HANDLE_VALUE
	// TODO: we must actually wait for a completion (poll again?)
	// https://stackoverflow.com/questions/79769834/winsock-can-an-overlapped-to-wsarecv-be-freed-immediately-after-calling-canceli
	if ctx.last_accept_op_data != nil {
	    // FIXME: test whether its correct to free OVERLAPPED for AcceptEx without waiting for completion on real network conditions
        free(ctx.last_accept_op_data, ctx.allocator)
	}

	// destroy allocator
	when tracy.TRACY_ENABLE {
	    profiler_data := cast(^tracy.ProfiledAllocatorData) ctx.allocator.data
		ctx.allocator = profiler_data.backing_allocator
        free(profiler_data, allocator)
	}
	when ODIN_DEBUG && !tracy.TRACY_ENABLE && !ODIN_TEST {
	    tracking_alloc := cast(^back.Tracking_Allocator) ctx.allocator.data
		back.tracking_allocator_print_results(tracking_alloc)
		back.tracking_allocator_destroy(tracking_alloc)
		ctx.allocator = tracking_alloc.backing
		free(tracking_alloc, allocator)
	}
    tlsf_alloc := cast(^tlsf.Allocator) ctx.allocator.data
	tlsf.destroy(tlsf_alloc)
	free(tlsf_alloc, allocator)
}

@(private="file")
_register_client :: proc(ctx: ^IOContext, conn: _ConnectionHandle) -> bool {
    tracy.Zone()
    handle := win32.HANDLE(conn.socket)

    register_result := win32.CreateIoCompletionPort(
        handle,
        ctx.completion_port,
        win32.ULONG_PTR(conn.socket),
        IOCP_CONCURRENT_THREADS,
    )
    if register_result != ctx.completion_port {
        _log_error(win32.GetLastError(), "failed to register client to iocp")
        return false
    }

    // don't bother setting up and signaling OVERLAPPED.hEvent, we are using iocp for notifications, not WaitForSingleObject and related logic
    // although this still doesnt let us repurpose hEvent to store user data, as winsock treats a non-zero value as an explicit event, regardless of this flag
    // (only if we also specify a lpCompletionRoutine, we are allowed to do this)
    if !win32.SetFileCompletionNotificationModes(handle, win32.FILE_SKIP_SET_EVENT_ON_HANDLE) {
        _log_error(win32.GetLastError(), "failed to set FILE_SKIP_SET_EVENT bit")
        return false
    }

    return _initiate_recv(ctx, conn)
}

// Non opaque ConnectionHandle variant, with win32 specific types.
// IMPORTANT NOTE: must be layout compatible with `ConnectionHandle`.
@(private="file")
_ConnectionHandle :: struct {
    socket: win32.SOCKET,
    // Heap allocated pointer to store the last recv buf raw_data, this data
    // is stored in a handle exchanged with the application, to ensure we retain access to it
    // for the whole lifetime of this connection. (the application has better means of storing this than we do).
    //
    // A buffer is stored at this address when a new connection handle is created, and is renewed every time a new recv buffer
    // is allocated. This way we always retain the last allocation, especially useful when disconnecting a client,
    // at this point no new iocp event will be emitted to confirm the disconnect, where we could simply grab the last allocated buf.
    // TODO
    last_read_op: ^IOOperationData,
    last_write_op: ^IOOperationData,
}
#assert(size_of(_ConnectionHandle) == size_of(ConnectionHandle))

// Initiate async recv call to emit an iocp event with the read data.
@(private="file")
_initiate_recv :: proc(ctx: ^IOContext, handle: _ConnectionHandle) -> bool {
    tracy.Zone()

    // alloc a new recv buffer per recv operation, we could in theory use two buffers per client
    // and rotate them, but a pool/slab allocator works good enough for this
    recv_buf: []u8
    {
        tracy.ZoneN("ALLOC_RECV")
        recv_buf = make([]u8, RECV_BUF_SIZE, ctx.allocator) or_else panic("OOM")
    }
    op_data := _alloc_operation_data(ctx^, .Read, handle.socket, recv_buf)

    flags: u32
	result := win32.WSARecv(
		handle.socket,
		&win32.WSABUF { RECV_BUF_SIZE, raw_data(recv_buf) },
		1,   /* buffer count */
		nil, /* nr of bytes received */
		&flags,
		cast(win32.LPWSAOVERLAPPED) &op_data.overlapped,
		nil, /* completion routine */
	)
	if result != 0 && win32.System_Error(win32.WSAGetLastError()) != .IO_PENDING {
	    _log_error(win32.WSAGetLastError(), "failed to initiate WSARecv")
		delete(recv_buf, ctx.allocator)
		free(op_data, ctx.allocator)
		return false
	}

	return true
}

// Cache line aligned IO operation data. The emitting socket is stored in lpCompletionKey of the OVERLAPPED_ENTRY.
@(private="file")
IOOperationData :: struct {
    overlapped: win32.OVERLAPPED,
    using _: struct #raw_union {
        // Only applicable when `op == .Read`.
	    read: struct {
			// Raw data of dynamically allocated recv buffer data, the size of this buffer is always `RECV_BUFFER_SIZE`.
			buf: [^]u8,
		},
		// Only applicable when `op == .Write`.
		write: struct {
		    // User allocated buffer that holds written data, in the case of partial writes, this always
    		// contains the whole write buffer, and `already_transfered` is used to indicate
    		// which part actually still needs to be transferred. (we must store the whole buffer to avoid leaking it)
			buf: []u8,
			already_transfered: u32,
		},
		// Only applicable when `op == .AcceptedConnection`.
		accepted_conn: struct {
		    socket: win32.SOCKET,
		},
	},
	op: IOOperation,
}
#assert(size_of(IOOperationData) == 64)

// IO operation as seen from our side.
@(private="file")
IOOperation :: enum u8 {
	Read,
	Write,
	AcceptedConnection,
}

// TODO: the issue with freeing IOOperationData after canceling IO is that the docs do not reliably tell us whether this is allowed
// or if we need to await the completion first (iocp wait/GetOverlappedResult). Even if we awaited the completion, we would not know whether
// we would poll again after this call.
@(private)
_unregister_client :: proc(ctx: ^IOContext, handle: ConnectionHandle) -> bool {
    tracy.Zone()
    // cancel outstanding io operations, yet to arrive completions will have a ERROR_OPERATION_ABORTED status.
    // this is the only way to unregister clients, there is no real "iocp unregister" procedure
    // This affects the installed WSARecv and potential WSASend operations
    ok := CancelIoEx(win32.HANDLE(win32.SOCKET(handle.socket)), /*cancel all*/ nil)

    // TODO: keep track of nr_outstanding or something and wait for completions instead of using ConnectionHandle
    // NOTE: we cannot actively rely on CancelIoEx emitting new iocp completions with an OPERATION_ABORTED status,
    // as this unregister is mosty only called after a peer has already hung up, thus the corresponding WSARecv has already completed
    // with an EOF before we even got here to call CancelIoEx, leaving us with an ERROR_NOT_FOUND indicating nothing could be canceled.
    // For this reason we use the ConnectionHandle struct, to still be able to track allocations
    // that would have otherwise become unreachable.
    //
    // Of course the cancelation is still applicable to write operations or cases where this unregister procedure
    // is called before the peer has hang up.
    if !ok && win32.System_Error(win32.GetLastError()) != .NOT_FOUND {
        _log_error(win32.GetLastError(), "failed to cancel outstanding io operations")
    }
    net.close(handle.socket)

	return true
}

@(private)
_await_io_completions :: proc(ctx: ^IOContext, completions_out: []Completion, timeout_ms: int) -> (n: int, ok: bool) {
    tracy.Zone()
	completion_entries := make([]win32.OVERLAPPED_ENTRY, len(completions_out), context.temp_allocator)
	nready: u32

	{
	    tracy.ZoneN("GetQueuedCompletionStatusEx")

        // NOTE: nothing is guaranteed in terms of dequeuing order, but we only have one concurrent read for each socket,
        // and potentially multiple writes, so this does not seem to be an issue
    	result := win32.GetQueuedCompletionStatusEx(
    		ctx.completion_port,
    		raw_data(completion_entries),
    		u32(len(completion_entries)),
    		&nready,
    		u32(timeout_ms),
    		fAlertable=false,
    	)
    	// instead of returning TRUE, 0, WAIT_TIMEOUT is being set
    	if !result && win32.System_Error(win32.GetLastError()) != .WAIT_TIMEOUT {
            _log_error(win32.GetLastError(), "failed to queue completion entries")
    		return
    	}
	}

	i := 0
	for entry in completion_entries[:nready] {
	    tracy.ZoneN("CompletionEntry")

		emitter := win32.SOCKET(entry.lpCompletionKey)
		#no_bounds_check comp := &completions_out[i]
  		comp.socket = net.TCP_Socket(emitter)

        // NOTE: care must be taken with or_continue to ensure this does not accidentally emit a completion
        // in a zeroed out state
        discard_entry := false
  		defer if discard_entry {
  		    nready -= 1
 			// if op_data.op == .Read {
 			    // TODO: get rid of this nonsense and emit an .Error comp instead
                    // _release_recv_buf(ctx, comp^)
 			// }
  		} else {
  		    i += 1
  		}

        // map IO NTSTATUS to win32 error
        // TODO: are we sure we need this translation?
        status := cast(win32.System_Error) RtlNtStatusToDosError(win32.NTSTATUS(entry.Internal))
        if status == .OPERATION_ABORTED {
            tracy.ZoneN("Stale Completion")
            // OVERLAPPED and operation data is already deallocated here, must not access it

            // TODO: what happens with last write operation, this contains an user allocated buffer, how do we pass it
            // back to them in order to free it?
            // TODO: reads are leaking here?

            discard_entry = true
            continue
        }

        op_data: ^IOOperationData = container_of(entry.lpOverlapped, IOOperationData, "overlapped")
		defer free(op_data, ctx.allocator)

        if status != .SUCCESS {
            // NOTE: when this entry refers to a write, it still holds an user allocated buffer
            // return this, so the application can free it
            comp.operation = .Error
            if op_data.op == .Write {
                comp.buf = op_data.write.buf
            }
 			continue
        }

		switch op_data.op {
		case .AcceptedConnection:
    		ctx.last_accept_op_data = nil
		    client_sock := op_data.accepted_conn.socket
            accept_success := false
            defer if !accept_success {
                _ = win32.closesocket(client_sock)
                discard_entry = true
            }

            _configure_accepted_client(ctx, client_sock) or_continue

            new_handle := _ConnectionHandle {
                socket = client_sock,
            }

            if !_register_client(ctx, new_handle) {
                continue
            }
            comp.operation = .NewConnection
            // TODO: instead of using the heap allocation, cant we use a double ended stack allocator,
            // where we allocate these pointers on one side (as they live for the whole connection lifecycle), and
            // recv buffers on the other side (more frequent freeing).
            //
            // TODO: also instead of using an opaque last_recv_op passed to the client, cant we just "tag" recv buffers in our
            // double ended stack, and search for the one represented by this connection (this wont be a perf issue with "lots" of clients right?)
            comp.handle = transmute(ConnectionHandle) new_handle // layout compatible
            accept_success = true

            // re-arm accept handler
            // TODO: consider this as being fatal, no more new clients can be accepted..
            _install_accept_handler(ctx) or_break
		case .Read:
			if entry.dwNumberOfBytesTransferred == 0 {
			    comp.operation = .PeerHangup
				comp.buf = op_data.read.buf[:RECV_BUF_SIZE]
			} else {
    			comp.operation = .Read
                comp.buf = op_data.read.buf[:entry.dwNumberOfBytesTransferred]

    			// re-arm recv handler
                handle := _ConnectionHandle {
                    socket = emitter,
                }
                // TODO: emit .Error instead of simply discarding this entry?
                discard_entry = !_initiate_recv(ctx, handle)
			}
		case .Write:
		    total_transfer := entry.dwNumberOfBytesTransferred + op_data.write.already_transfered
		    partial_write := int(total_transfer) != len(op_data.write.buf)
			transport_buf := op_data.write.buf
			if partial_write {
			    // ignore this entry, query another send with the remaining part of the buffer
				discard_entry = true

				_initiate_send(ctx, emitter, transport_buf, partial_write_off=total_transfer) or_continue
				continue
			}

			assert(int(entry.dwNumberOfBytesTransferred) == len(op_data.write.buf), "partial writes should be handled above")
		    comp.operation = .Write
			// for caller to deallocate
			comp.buf = transport_buf
		}
	}

	return int(nready), true
}

@(private)
_release_recv_buf :: proc(ctx: ^IOContext, comp: Completion) {
    tracy.Zone()
    assert(raw_data(comp.buf) != nil)
    delete(comp.buf, ctx.allocator)
}

// TODO: don't actually flush on every call
@(private)
_submit_write_copy :: proc(ctx: ^IOContext, handle: ConnectionHandle, data: []u8) -> bool {
    tracy.Zone()
    handle := transmute(_ConnectionHandle) handle

    return _initiate_send(ctx, handle.socket, data)
}

@(private="file")
_initiate_send :: proc(ctx: ^IOContext, socket: win32.SOCKET, data: []u8, partial_write_off: u32 = 0) -> bool {
    tracy.Zone()

    op_data := _alloc_operation_data(ctx^, .Write, socket, data)
    op_data.write.already_transfered = partial_write_off

    // handle potential partial writes, send this buffer while we keep storing the original in order to free it later
    data := data[partial_write_off:]
    // this returns WSAENOTSOCK when the socket is already closed
    result := win32.WSASend(
        socket,
        &win32.WSABUF { u32(len(data)), raw_data(data) },
        1,  /* buffer count */
        nil,
        0,  /* flags */
        cast(win32.LPWSAOVERLAPPED) &op_data.overlapped,
        nil, /* completion routine */
    )
    if result != 0 && win32.System_Error(win32.WSAGetLastError()) != .IO_PENDING {
        _log_error(win32.WSAGetLastError(), "failed to initiate WSASend")
        free(op_data, ctx.allocator)
        return false
    }
    return true
}

@(private="file")
_configure_accepted_client :: proc(ctx: ^IOContext, client_sock: win32.SOCKET) -> bool {
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
	// setsockopt among other procedures work
	result := win32.setsockopt(
		client_sock,
        win32.SOL_SOCKET,
        win32.SO_UPDATE_ACCEPT_CONTEXT,
        &ctx.server_sock, size_of(ctx.server_sock),
	)
	if result != 0 {
	    return false
	}

	if net.set_blocking(net.TCP_Socket(client_sock), false) != .None {
	    return false
	}
	if net.set_option(net.TCP_Socket(client_sock), .TCP_Nodelay, true) != .None {
	    return false
	}
	return true
}

@(private="file")
_alloc_operation_data :: proc(ctx: IOContext, $Op: IOOperation, source: win32.SOCKET, buf: []u8) -> ^IOOperationData {
    tracy.Zone()

    op_data := new(IOOperationData, ctx.allocator) or_else panic("OOM")
    op_data.op = Op
    when Op == .Write {
        op_data.write.buf = buf
    } else when Op == .Read {
        op_data.read.buf = raw_data(buf)
    }

    return op_data
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

@(private)
_log_error_impl :: proc(#any_int err: win32.DWORD, message: string) {
    log.logf(ERROR_LOG_LEVEL, "%s: %s", message, win32.System_Error(err))
}