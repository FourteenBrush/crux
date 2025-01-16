package crux

ServerboundPacket :: union {
    HandshakePacket,
}

// 7 least significant bits are used to encode the value,
// most significant bits indicate whether there's another byte
VarInt :: distinct i32be
VarLong :: distinct i64be

NextState :: enum VarInt {
    Status   = 1,
    Login    = 2,
    Transfer = 3,
}

String :: struct {
    length: VarInt,
    data: [^]u8,
}

PacketId :: enum VarInt {
    Handshake = 0x00,
}

HandshakePacket :: struct {
    protocol_version: VarInt,
    server_addr: String,
    server_port: u16be,
    next_state: NextState,
}

ConnectionState :: enum VarInt {
    Status = 1,
    Login = 2,
    Transfer = 3,
}
