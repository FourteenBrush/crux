package crux

import "core:log"
import "core:mem"

// TODO: on error: differentiate between simply not enough bytes to read and an invalid formed packet
// in which the latter should kick the client
read_serverbound :: proc(b: ^NetworkBuffer, allocator: mem.Allocator) -> (p: ServerboundPacket, err: ReadError) {
    // either a legacy server ping or a minimal packet
    if consume_u16_if(b, 0xfe01) or_return {
        // i suppose this wont be ambiguous with a serverbound ping request, which has packet_id 0x01
        // as its length is always a varint + long, which is definitely smaller than 0xfe (254)
        // TODO: use rest of the packet
        return LegacyServerPingPacket {}, .None
    }
    // TODO: do some pos marking in case we dont have enough bytes to read the full packet
    
    length := read_var_int(b) or_return
    id := read_var_int(b) or_return

    ensure_readable(b^, length) or_return

    #partial switch PacketId(id) {
    case .Handshake:
        // TODO: validation
        protocol_version := read_var_int(b) or_return
        server_addr := read_string(b, allocator) or_return
        server_port := read_u16(b) or_return
        next_state := ClientState(read_var_int(b) or_return)

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
