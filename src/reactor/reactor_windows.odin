package reactor

import "core:log"
import "core:mem"
import "core:net"
import "core:time"
import "core:mem/tlsf"
import win32 "core:sys/windows"

import "lib:tracy"

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
	timer_resolution: u32,
	// Number of outstanding network operations which have not yet produced a completion.
	outstanding_net_ops: u32,
	// Allocator used to allocate io operation data and recv buffers.
	// TODO: separate into two allocators, one for per client recv bufs/write bufs (maybe) and
	// one for completion entries, freelist block based
	allocator: mem.Allocator,

	// Buf where local and remote addr are placed on an AcceptEx call.
	// TODO: can we somehow put this in the IOOperationData, maybe as flexible array member?
	accept_buf: [ADDR_BUF_SIZE * 2]u8,
}

@(private)
_create_io_context :: proc(server_sock: net.TCP_Socket, allocator: mem.Allocator) -> (ctx: IOContext, ok: bool) {
    tracy.Zone()
    // NOTE: while it would be theoretically more interesting to only surround the timing critical GetQueuedCompletionStatusEx
    // call with a timeBeginPeriod/timeEndPeriod (to save power etc..), this does not reliably affect the timer
    // resolution (especially for code that only runs in this short period). For instance, switching power modes has a negative
    // effect on the timer resolution, effectively bringing us back to the ~15ms default resolution time...
    // TODO: take a look at CreateWaitableTimerEx with CREATE_WAITABLE_TIMER_HIGH_RESOLUTION flag and make this emit
    // iocp packets.
    timecaps: win32.TIMECAPS
    res := win32.timeGetDevCaps(&timecaps, size_of(timecaps))
    assert(res == win32.MMSYSERR_NOERROR, "failed querying timer resolution")
    ctx.timer_resolution = max(1, timecaps.wPeriodMin)
    res = win32.timeBeginPeriod(ctx.timer_resolution)
    assert(res == win32.TIMERR_NOERROR, "invariant, resolution should not be out of range")

    ctx.completion_port = win32.CreateIoCompletionPort(
		win32.INVALID_HANDLE_VALUE,
		win32.HANDLE(nil),
		0, /* completion key (ignored) */
		0  /* use as many concurrent worker threads as there are processors */,
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
	
	ctx.allocator = _make_instrumented_alloc(
		backing=tlsf.allocator(tlsf_alloc),
		meta_allocator=allocator,
	)
	defer if !ok {
		_destroy_instrumented_alloc(instrumented=ctx.allocator, meta_allocator=allocator)
	  	tlsf.destroy(tlsf_alloc)
		free(tlsf_alloc, allocator)
	}
	
	// allow server sock to emit iocp packets for new connections (through AcceptEx)
	result := win32.CreateIoCompletionPort(
	    win32.HANDLE(ctx.server_sock),
		ctx.completion_port,
		win32.ULONG_PTR(ctx.server_sock),
		0 /* nr of concurrent threads (ignored) */,
	)
	if result != ctx.completion_port && win32.GetLastError() != win32.ERROR_IO_PENDING {
	    _log_error(win32.GetLastError(), "failed to register server socket to completion port")
	    return
	}
	
	_install_accept_handler(&ctx) or_return

	return ctx, true
}

// Installs an `AcceptEx` handler to the context, which will emit IOCP packets for inbound connections.
@(private="file")
_install_accept_handler :: proc(ctx: ^IOContext) -> bool {
    tracy.Zone()

    // socket that AcceptEx will use to bind the accepted client to,
    // implicitly configured for overlapped IO
    client_sock := win32.socket(win32.AF_INET, win32.SOCK_STREAM, win32.IPPROTO_TCP)
	if client_sock == win32.INVALID_SOCKET {
	    _log_error(win32.WSAGetLastError(), "could not create client socket")
		return false
	}

	op_data := _alloc_operation_data(ctx^, .AcceptedConnection, ctx.server_sock, nil)
	op_data.accepted_conn.socket = client_sock

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
		return false
	}
	
	ctx.outstanding_net_ops += 1
	return true
}

@(private)
_destroy_io_context :: proc(ctx: ^IOContext, allocator: mem.Allocator) {
    // cancel AcceptEx call
    _ = win32.CancelIoEx(win32.HANDLE(ctx.server_sock), nil)
    
    _reap_pending_completions(ctx)
    win32.timeEndPeriod(ctx.timer_resolution)

	win32.CloseHandle(ctx.completion_port)
	ctx.completion_port = win32.INVALID_HANDLE_VALUE
	// as all overlapped IO operations on the server socket are cancelled, there should
	// be no issues in still having it bound to this iocp
	
	tlsf_allocator := _destroy_instrumented_alloc(instrumented=ctx.allocator, meta_allocator=allocator)
	tlsf_alloc := cast(^tlsf.Allocator) tlsf_allocator.data
	tlsf.destroy(tlsf_alloc)
	free(tlsf_alloc, allocator)
}

@(private="file")
_reap_pending_completions :: proc(ctx: ^IOContext) {
	if ctx.outstanding_net_ops == 0 do return
	
	// await completion for all cancelled io operations (read/writes/accepts)
	// https://stackoverflow.com/questions/79769834/winsock-can-an-overlapped-to-wsarecv-be-freed-immediately-after-calling-canceli
   	total_outstanding := ctx.outstanding_net_ops
	entries := make([]win32.OVERLAPPED_ENTRY, ctx.outstanding_net_ops, context.temp_allocator)
	
	start := time.tick_now()
	LINGER_SECS :: 15
	hit_deadline := false

 	for ctx.outstanding_net_ops > 0 && !hit_deadline {
		nready := _poll_iocp(ctx, entries, timeout_ms=1000) or_break
		
		for entry in entries[:nready] {
			op_data: ^IOOperationData = container_of(entry.lpOverlapped, IOOperationData, "overlapped")
			defer free(op_data, ctx.allocator)
			
			// we don't care about the status, just grab the operation and perform cleanup
			switch op_data.op {
			case .AcceptedConnection:
				win32.closesocket(op_data.accepted_conn.socket)
			case .Read:
				_release_recv_buf(ctx, op_data.read.buf)
			case .Write:
				// TODO: ideally pass allocated buffer back upstream, but we have no way to communicate with the upstream here
			}
		}
		
		ctx.outstanding_net_ops -= nready
		if ctx.outstanding_net_ops > 0 && time.duration_seconds(time.tick_since(start)) >= LINGER_SECS {
			hit_deadline = true
			log.logf(
				ERROR_LOG_LEVEL,
				"failed to collect completions for %d cancelled io operations in time, leaking memory..",
				ctx.outstanding_net_ops,
			)
		}
 	}
		
	collected_completions := total_outstanding - ctx.outstanding_net_ops
	if collected_completions > 0 {
		log.logf(ERROR_LOG_LEVEL, "collected %d io completions in %v", total_outstanding - ctx.outstanding_net_ops, time.tick_since(start))
	}
}

@(private="file")
_register_client :: proc(ctx: ^IOContext, conn: win32.SOCKET) -> bool {
    tracy.Zone()
    handle := win32.HANDLE(conn)

    register_result := win32.CreateIoCompletionPort(
        handle,
        ctx.completion_port,
        win32.ULONG_PTR(conn),
        0 /* nr of concurrent threads (ignored) */,
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

// Initiate async recv call to emit an iocp packet with the read data.
@(private="file")
_initiate_recv :: proc(ctx: ^IOContext, conn: win32.SOCKET) -> bool {
    tracy.Zone()

    // alloc a new recv buffer per recv operation, we could in theory use two buffers per client
    // and rotate them, but a pool/slab allocator works good enough for this
    recv_buf: []u8
    {
        tracy.ZoneN("ALLOC_RECV")
        recv_buf = mem.alloc_bytes_non_zeroed(RECV_BUF_SIZE, align_of(u8), ctx.allocator) or_else panic("OOM")
    }
    op_data := _alloc_operation_data(ctx^, .Read, conn, recv_buf)

    flags: u32
	result := win32.WSARecv(
		conn,
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

	ctx.outstanding_net_ops += 1
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
			buf: []u8,
		},
		// Only applicable when `op == .Write`.
		write: struct {
		    // User allocated buffer that holds written data, in the case of partial writes, this always
    		// contains the whole write buffer, and `already_transferred` is used to indicate
    		// which part actually still needs to be transferred. (we must store the whole buffer to avoid leaking it)
			buf: []u8,
			already_transferred: u32,
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

@(private)
_unregister_client :: proc(ctx: ^IOContext, conn: net.TCP_Socket) -> bool {
    tracy.Zone()
    // This affects the installed WSARecv and potential WSASend operations
    // NOTE: it seems like it is safe to close the client socket with completion packets still in flight,
    // but only with CancelIoEx, not with CancelIo
    ok := win32.CancelIoEx(win32.HANDLE(win32.SOCKET(conn)), /*cancel all*/ nil)
    
    // NOTE: after cancellation, in flight network operations will either return an iocp packet
    // with an ERROR_OPERATION_ABORTED status (which will then be discarded), or will still produce a successful status (or error)
    // in the case where they could not be cancelled in time. In the latter case they will produce a valid Completion, and
    // the upstream is responsable for guarding against those stale completions (as we do not track connected clients).
    //
    // For all in flight operations, an iocp packet needs to be collected before the associated resources can be deallocated
    // (io operation data and eventual buffers). In practice this means polling again when shutting down the io context
    // (after all connections have been unregistered first), or doing this implicitly when a connection gets unregistered
    // in the middle of the io context's lifetime.

    if !ok && win32.System_Error(win32.GetLastError()) != .NOT_FOUND {
        _log_error(win32.GetLastError(), "failed to cancel outstanding io operations")
    }
    
    // There is no way to disassociate a socket from a iocp, instead we just cancel operations, and close the socket,
    // the latter will implicitly unregister it from the completion port.
    net.close(conn)

	return true
}

@(private="file")
_poll_iocp :: proc(ctx: ^IOContext, entries_out: []win32.OVERLAPPED_ENTRY, timeout_ms: int) -> (nready: u32, ok: bool) {
	tracy.ZoneN("GetQueuedCompletionStatusEx")
		
    // NOTE: nothing is guaranteed in terms of dequeuing order, but we only have one concurrent read for each socket,
    // and potentially multiple writes, so this does not seem to be an issue
    // TODO: enforce write completions are assembled in order (especially when sending lots of them per client),
    // perhaps we should handle buffering ourselves
   	success := win32.GetQueuedCompletionStatusEx(
  		ctx.completion_port,
  		raw_data(entries_out),
  		u32(len(entries_out)),
  		&nready,
    	u32(timeout_ms),
  		fAlertable=false,
   	)
   	if !success && win32.System_Error(win32.GetLastError()) != .WAIT_TIMEOUT {
        _log_error(win32.GetLastError(), "failed to queue completion entries")
  		return
   	}
    return nready, true
}

@(private)
_await_io_completions :: proc(ctx: ^IOContext, completions_out: []Completion, timeout_ms: int) -> (n: int, ok: bool) {
    tracy.Zone()
    
	completion_entries := make([]win32.OVERLAPPED_ENTRY, len(completions_out), context.temp_allocator)
	nready := _poll_iocp(ctx, completion_entries, timeout_ms) or_return

	i := 0
	for entry in completion_entries[:nready] {
	    tracy.ZoneN("CompletionEntry")

		emitter := win32.SOCKET(entry.lpCompletionKey)
		#no_bounds_check comp := &completions_out[i]
  		comp.socket = net.TCP_Socket(emitter)

        // NOTE: care must be taken with or_continue to ensure this does not accidentally emit a zeroed out completion
        discard_entry := false
  		defer if discard_entry {
  		    nready -= 1
  		} else {
  		    i += 1
  		}
	    ctx.outstanding_net_ops -= 1

        io_status := cast(win32.System_Error) win32.RtlNtStatusToDosError(win32.NTSTATUS(entry.Internal))
        op_data: ^IOOperationData = container_of(entry.lpOverlapped, IOOperationData, "overlapped")
		defer free(op_data, ctx.allocator)
		
        if io_status == .OPERATION_ABORTED {
            tracy.ZoneN("Stale Completion")
            // TODO: what happens with last write operation, this contains an user allocated buffer, how do we pass it back?
            
            if op_data.op == .Read {
	           	_release_recv_buf(ctx, op_data.read.buf)
            }

            discard_entry = true
            continue
        }

        if io_status != .SUCCESS {
            comp.operation = .Error
            if op_data.op == .Write {
            	// pass user allocated buf back upstream
                comp.buf = op_data.write.buf
            }
 			continue
        }

		switch op_data.op {
		case .AcceptedConnection:
		    client_sock := op_data.accepted_conn.socket
            accept_success := false
            defer if !accept_success {
                win32.closesocket(client_sock)
                discard_entry = true
            }

            _configure_accepted_client(ctx, client_sock) or_continue
            _register_client(ctx, client_sock) or_continue
            
            comp.operation = .NewConnection
            comp.socket = net.TCP_Socket(client_sock)
            accept_success = true

            // re-arm accept handler, NOTE: fatal if this fails, no new connections can be accepted
            _install_accept_handler(ctx) or_break
		case .Read:
			if entry.dwNumberOfBytesTransferred == 0 {
			    comp.operation = .PeerHangup
				comp.buf = op_data.read.buf
			} else {
    			comp.operation = .Read
                comp.buf = op_data.read.buf[:entry.dwNumberOfBytesTransferred]

    			// re-arm recv handler
                if !_initiate_recv(ctx, emitter) {
                	comp.operation = .Error
                 	comp.buf = nil
                }
			}
		case .Write:
		    total_transfer := entry.dwNumberOfBytesTransferred + op_data.write.already_transferred
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
			comp.buf = transport_buf // pass back to upstream to deallocate
		}
	}

	return int(nready), true
}

@(private)
_release_recv_buf :: proc(ctx: ^IOContext, buf: []u8) {
    tracy.Zone()
    delete(buf, ctx.allocator)
}

// TODO: don't actually flush on every call
@(private)
_submit_write_copy :: proc(ctx: ^IOContext, conn: net.TCP_Socket, data: []u8) -> bool {
    tracy.Zone()

    return _initiate_send(ctx, win32.SOCKET(conn), data)
}

@(private="file")
_initiate_send :: proc(ctx: ^IOContext, socket: win32.SOCKET, data: []u8, partial_write_off: u32 = 0) -> bool {
    tracy.Zone()

    op_data := _alloc_operation_data(ctx^, .Write, socket, data)
    op_data.write.already_transferred = partial_write_off

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
    
    ctx.outstanding_net_ops += 1
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
        op_data.read.buf = buf
    }

    return op_data
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
