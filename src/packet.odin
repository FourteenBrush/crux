package crux

import "core:reflect"
import "base:intrinsics"

ServerboundPacket :: union {
    LegacyServerListPingPacket,
    HandshakePacket,
    StatusRequestPacket,
    PingRequest,
}

ClientBoundPacket :: union #no_nil {
    StatusResponsePacket,
    PongResponse,
}

// 7 least significant bits are used to encode the value,
// most significant bit indicates whether there's another byte
VarInt :: distinct i32le
VarLong :: distinct i64le

Long :: distinct i64be

Utf16String :: distinct []u8

PacketId :: enum VarInt {
    Handshake      = 0x00,
    StatusRequest  = 0x00,
    StatusResponse = 0x00, // CLIENTBOUND
    // To calculate the server's latency
    PingRequest    = 0x01,
    PongResponse   = 0x01, // CLIENTBOUND
}

get_clientbound_packet_id :: proc(packet: ClientBoundPacket) -> PacketId {
    tag: i64 = reflect.get_union_variant_raw_tag(packet)
    return clientbound_packet_id_lookup[tag]
}

@(private)
VARIANT_IDX_OF :: intrinsics.type_variant_index_of

// mapping of ClientBoundPacket raw union tags to packet ids
// IMPORTANT NOTE: ClientBoundPacket must be #no_nil or we need a +1 on the variant idx
@(rodata, private)
clientbound_packet_id_lookup := [intrinsics.type_union_variant_count(ClientBoundPacket)]PacketId {
    VARIANT_IDX_OF(ClientBoundPacket, StatusResponsePacket) = .StatusResponse,
    VARIANT_IDX_OF(ClientBoundPacket, PongResponse) = .PongResponse,
}

HandshakePacket :: struct {
    protocol_version: ProtocolVersion,
    server_addr: string,
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

PingRequest :: struct {
    payload: Long,
}

ConnectionState :: enum VarInt {
    Status = 1,
    Login = 2,
    Transfer = 3,
}

// Only the version.name field should be considered mandatory
StatusResponsePacket :: struct {
    version: struct {
        name: string `json:"name"`,
        protocol: ProtocolVersion `json:"protocol"`,
    },
    players: struct { max: uint, online: uint },
    // TODO: make TextComponent
    description: struct { text: string },
    favicon: string,
    enforces_secure_chat: bool `json:"enforcesSecureChat"`,
}

PongResponse :: struct {
    payload: Long,
}