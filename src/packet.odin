package crux

ServerboundPacket :: union {
    LegacyServerListPingPacket,
    HandshakePacket,
    StatusRequestPacket,
}

ClientBoundPacket :: union {
    StatusResponsePacket,
}

// 7 least significant bits are used to encode the value,
// most significant bits indicate whether there's another byte
VarInt :: distinct i32le
VarLong :: distinct i64le

// FIXME: use an odin string, why bother storing len as a VarInt?
// only reason i could think of is packing it for transmission, but we generally already mess up
// with either an []u8 or [^]u8
String :: struct {
    length: VarInt,
    data: []u8 `fmt:"s"`,
}

Utf16String :: distinct []u8

PacketId :: enum VarInt {
    Handshake = 0x00,
    StatusRequest = 0x00,
}

HandshakePacket :: struct {
    protocol_version: ProtocolVersion,
    server_addr: String,
    server_port: u16be,
    intent: ClientState,
}

LegacyServerListPingPacket :: struct {
    v1_6_extension: Maybe(LegacyServerListPingV1_6Extension),
}

LegacyServerListPingV1_6Extension :: struct {
    plugin_msg_packet_id: u8,
    channel: Utf16String,
    protocol_version: u8,
    hostname: Utf16String,
    port: i32be,
}

StatusRequestPacket :: struct {}

ConnectionState :: enum VarInt {
    Status = 1,
    Login = 2,
    Transfer = 3,
}

StatusResponsePacket :: struct {
    version_name: string `json:"version"`,
    version_protocol: uint `json:"protocol"`,
    players: struct { max: uint, online: uint },
    description: struct { text: string },
    favicon: string,
    enforces_secure_chat: bool `json:"enforcesSecureChat"`,
}
