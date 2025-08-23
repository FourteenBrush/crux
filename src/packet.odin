package crux

import "core:reflect"
import "base:intrinsics"

ServerBoundPacket :: union #no_nil {
    LegacyServerListPingPacket,
    HandshakePacket,
    StatusRequestPacket,
    PingRequestPacket,
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

ServerBoundPacketId :: enum VarInt {
    Handshake      = 0x00,
    StatusRequest  = 0x00,
    // To calculate the server's latency
    PingRequest    = 0x01,
}

ClientBoundPacketId :: enum VarInt {
    StatusResponse = 0x00, // CLIENTBOUND
    PongResponse   = 0x01, // CLIENTBOUND
}

get_clientbound_packet_id :: proc(packet: ClientBoundPacket) -> ClientBoundPacketId {
    tag: i64 = reflect.get_union_variant_raw_tag(packet)
    #no_bounds_check return clientbound_packet_id_lookup[tag]
}

@(private)
VARIANT_IDX_OF :: intrinsics.type_variant_index_of

// mapping of ClientBoundPacket raw union tags to packet ids
// IMPORTANT NOTE: ClientBoundPacket must be #no_nil or we need a +1 on the variant idx
@(rodata, private)
clientbound_packet_id_lookup := [intrinsics.type_union_variant_count(ClientBoundPacket)]ClientBoundPacketId {
    VARIANT_IDX_OF(ClientBoundPacket, StatusResponsePacket) = .StatusResponse,
    VARIANT_IDX_OF(ClientBoundPacket, PongResponse) = .PongResponse,
}

get_serverbound_packet_descriptor :: proc(packet: ServerBoundPacket) -> ServerBoundPacketDescriptor {
    tag: i64 = reflect.get_union_variant_raw_tag(packet)
    return serverbound_packet_descriptors[tag]
}

// IMPORTANT NOTE: ServerBoundPacket must be #no_nil or we need a +1 on the variant idx
@(rodata, private)
serverbound_packet_descriptors := [intrinsics.type_union_variant_count(ServerBoundPacket)]ServerBoundPacketDescriptor {
    // TODO: is this packet allowed in multiple states?
    VARIANT_IDX_OF(ServerBoundPacket, LegacyServerListPingPacket) = { .Handshake },
    VARIANT_IDX_OF(ServerBoundPacket, HandshakePacket)            = { .Handshake },
    VARIANT_IDX_OF(ServerBoundPacket, StatusRequestPacket)        = { .Status },
    VARIANT_IDX_OF(ServerBoundPacket, PingRequestPacket)          = { .Status },
}

ServerBoundPacketDescriptor :: struct {
    // Client state in which this packet should arrive.
    expected_client_state: ClientState,
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

PingRequestPacket :: struct {
    payload: Long,
}

ConnectionState :: enum VarInt {
    Status = 1,
    Login = 2,
    Transfer = 3,
}

// Only the version.name field should be considered mandatory
// TODO: place json:omitempty tags
StatusResponsePacket :: struct {
    version: struct {
        name: string `json:"name"`,
        protocol: ProtocolVersion `json:"protocol"`,
    },
    players: struct { max: uint, online: uint },
    // TODO: make TextComponent
    description: struct {
        text: string,
    },
    favicon: string,
    enforces_secure_chat: bool `json:"enforcesSecureChat"`,
}

PongResponse :: struct {
    payload: Long,
}