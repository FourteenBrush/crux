package crux

String :: struct {
    length: VarInt,
    data: [^]u8,
}

PacketHeader :: struct #packed {
    length: VarInt,
    id: PacketId,
}

PacketId :: enum VarInt {
    Handshake = 0x00,
}

HandshakePacket :: struct {
    protocol_version: VarInt,
    server_addr: String,
    server_port: u16be,
    next_state: VarInt,
}

ConnectionState :: enum VarInt {
    Status = 1,
    Login = 2,
    Transfer = 3,
}
