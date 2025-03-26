package crux

ServerboundPacket :: union {
    HandshakePacket,
}

// 7 least significant bits are used to encode the value,
// most significant bits indicate whether there's another byte
VarInt :: distinct i32le
VarLong :: distinct i64le

NextState :: enum VarInt {
    Status   = 1,
    Login    = 2,
    Transfer = 3,
}

// FIXME: use an odin string, why bother storing len as a VarInt?
// only reason i could think of is packing it for transmission, but we generally already mess up
// with either an []u8 or [^]u8
String :: struct {
    length: VarInt,
    data: []u8 `fmt:"s"`,
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
