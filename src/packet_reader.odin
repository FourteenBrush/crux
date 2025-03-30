package crux

import "core:log"
import "core:mem"

// TODO: on error: differentiate between simply not enough bytes to read and an invalid formed packet
// in which the latter should kick the client
read_serverbound :: proc(b: ^NetworkBuffer, allocator: mem.Allocator) -> (p: ServerboundPacket, err: ReadError) {
    if consume_u16(b, 0xfe01) or_return {
        // NOTE: vanilla client attempts to send a legacy server list ping packet
        // when normal ping times out (30s)
        // i suppose this wont be ambiguous with a serverbound ping request, which has packet_id 0x01
        // as its length is always a varint + long, which is definitely smaller than 0xfe (254)
        // TODO: read rest of the packet
        return LegacyServerPingPacket {}, .None
    }
    
    // early return on short read, no bytes consumed
    length, length_nbytes := peek_var_int(b) or_return
    ensure_readable(b^, length) or_return

    advance_pos_unchecked(b, length_nbytes)
    log.debug(length, b.r_offset, length_nbytes, b.len)
    id := read_var_int(b) or_return

    #partial switch PacketId(id) {
    case .Handshake:
        // TODO: validation
        protocol_version := read_var_int(b) or_return
        server_addr := read_string(b, allocator) or_return
        server_port := read_u16(b) or_return
        next_state := read_client_state(b, min=.Status) or_return

        return HandshakePacket {
            protocol_version = protocol_version,
            server_addr = server_addr,
            server_port = server_port,
            next_state = next_state,
        }, .None
    case:
        log.warn("unhandled packet id:", PacketId(id))
        return p, .InvalidData
    }
}

read_protocol_version :: proc(b: ^NetworkBuffer) -> (p: ProtocolVersion, err: ReadError) {
    val := read_var_int(b) or_return
    protocol_valid := true // TODO: use table in protcol_version.odin
    return ProtocolVersion(val), .None if protocol_valid else .InvalidData
}

read_client_state :: proc(b: ^NetworkBuffer, min: ClientState) -> (c: ClientState, err: ReadError) {
    val := read_var_int(b) or_return
    if ClientState(val) < min || ClientState(val) > max(ClientState) {
        return c, .InvalidData
    }
    return ClientState(val), .None
}
