package crux

import "core:reflect"
import "base:intrinsics"
import "core:encoding/uuid"

// FIXME: cant we avoid having a tagged union inside another one?
Packet :: union { ClientBoundPacket, ServerBoundPacket }

ServerBoundPacket :: union #no_nil {
    // sent in .Handshake state
    LegacyServerListPingPacket,
    HandshakePacket,
    // sent in .Status state
    StatusRequestPacket,
    PingRequestPacket,
    // sent in .Login state
    LoginStartPacket,
    LoginAcknowledgedPacket,
    // sent in .Configuration state
    PluginMessagePacket,
    ClientInformationPacket,
}

ServerBoundPacketId :: enum VarInt {
    // sent in .Handshake state
    Handshake           = 0x00,
    
    // sent in .Status state
    
    StatusRequest       = 0x00,
    // To calculate the server's latency
    PingRequest         = 0x01,
    
    // sent in .Login state
    
    LoginStart          = 0x00,
    LoginAcknowledged   = 0x03,
    
    // send in .Configuration state
    
    PluginMessage       = 0x02,
    ClientInformation   = 0x00,
}

ClientBoundPacket :: union #no_nil {
    StatusResponsePacket,
    PongResponsePacket,
    LoginSuccessPacket,
    DisconnectConfigurationPacket,
    PluginMessagePacket,
}

ClientBoundPacketId :: enum VarInt {
    // sent in Status state
    
    StatusResponse = 0x00,
    PongResponse   = 0x01,
    
    // sent in Login state
    
    LoginSuccess   = 0x02,
    
    // sent in Login state
    
    
    // sent in Configuration state

    PluginMessage  = 0x01,
    Disconnect     = 0x02,
}

get_clientbound_packet_id :: proc(packet: ClientBoundPacket) -> ClientBoundPacketId {
    tag: i64 = reflect.get_union_variant_raw_tag(packet)
    #no_bounds_check return clientbound_packet_id_lookup[tag]
}

@(private)
VARIANT_IDX_OF :: intrinsics.type_variant_index_of

// mapping of ClientBoundPacket raw union tags to packet ids
// IMPORTANT NOTE: ClientBoundPacket must be #no_nil or we need a +1 on the variant idx
@(rodata, private="file")
clientbound_packet_id_lookup := [intrinsics.type_union_variant_count(ClientBoundPacket)]ClientBoundPacketId {
    VARIANT_IDX_OF(ClientBoundPacket, StatusResponsePacket)          = .StatusResponse,
    VARIANT_IDX_OF(ClientBoundPacket, PongResponsePacket)            = .PongResponse,
    VARIANT_IDX_OF(ClientBoundPacket, LoginSuccessPacket)            = .LoginSuccess,
    VARIANT_IDX_OF(ClientBoundPacket, DisconnectConfigurationPacket) = .Disconnect,
    VARIANT_IDX_OF(ClientBoundPacket, PluginMessagePacket)           = .PluginMessage,
}

get_serverbound_packet_descriptor :: proc(packet: ServerBoundPacket) -> ServerBoundPacketDescriptor {
    tag: i64 = reflect.get_union_variant_raw_tag(packet)
    #no_bounds_check return serverbound_packet_descriptors[tag]
}

// IMPORTANT NOTE: ServerBoundPacket must be #no_nil or we need a +1 on the variant idx
@(rodata, private="file")
serverbound_packet_descriptors := [intrinsics.type_union_variant_count(ServerBoundPacket)]ServerBoundPacketDescriptor {
    // TODO: is this packet allowed in multiple states?
    // TODO: make expected_client_state Maybe(ClientState) (this can be a constant since around 19/09 as Maybe has only one variant); wait for release dev-10
    VARIANT_IDX_OF(ServerBoundPacket, LegacyServerListPingPacket) = { .Handshake },
    VARIANT_IDX_OF(ServerBoundPacket, HandshakePacket)            = { .Handshake },
    VARIANT_IDX_OF(ServerBoundPacket, StatusRequestPacket)        = { .Status },
    VARIANT_IDX_OF(ServerBoundPacket, PingRequestPacket)          = { .Status },
    VARIANT_IDX_OF(ServerBoundPacket, LoginStartPacket)           = { .Login },
    VARIANT_IDX_OF(ServerBoundPacket, LoginAcknowledgedPacket)    = { .Login },
    VARIANT_IDX_OF(ServerBoundPacket, PluginMessagePacket)        = { .Configuration },
    VARIANT_IDX_OF(ServerBoundPacket, ClientInformationPacket)    = { .Configuration },
}

ServerBoundPacketDescriptor :: struct {
    // Client state in which this packet should arrive.
    expected_client_state: ClientState,
}

HandshakePacket :: struct {
    protocol_version: ProtocolVersion,
    server_addr: string,
    server_port: u16be,
    intent: HandshakeIntent,
}

// IMPORTANT NOTE: values must match respective values from ConnectionState to allow casting
HandshakeIntent :: enum VarInt {
    Status    = 1,
    Login     = 2,
    Transfer  = 3,
}

LegacyServerListPingPacket :: struct {
    v1_6_extension: Maybe(LegacyServerListPingV1_6Extension),
}

// TODO: use string16 type when odin tagged release appears (actually dont and revision if this is even a utf16 string)
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

LoginStartPacket :: struct {
    username: string /*(16)*/,
    uuid: uuid.Identifier,
}

LoginAcknowledgedPacket :: struct {}

PluginMessagePacket :: struct {
    channel: Identifier,
    payload: []u8 `fmt:"s"`,
}

ClientInformationPacket :: struct {
    locale: string /*(16)*/,
    view_distance: u8,
    chat_mode: ChatMode,
    chat_colors: bool,
    skin_parts: SkinParts,
    main_hand: MainHand,
    enable_text_filtering: bool,
    allow_server_listings: bool,
    particle_status: ParticleStatus,
}

ChatMode :: enum VarInt {
    Enabled      = 0,
    CommandsOnly = 1,
    Hidden       = 2,
}

SkinParts :: bit_set[SkinPart; u8]
// Bit positions for a skin parts bit set
SkinPart :: enum {
    Cape          = 0,
    Jacket        = 1,
    LeftSleeve    = 2,
    RightSleeve   = 3,
    LeftPantsLeg  = 4,
    RightPantsLeg = 5,
    Hat           = 6,
}

MainHand :: enum VarInt {
    Left  = 0,
    Right = 1,
}

ParticleStatus :: enum VarInt {
    All       = 0,
    Decreased = 1,
    Minimal   = 2,
}

ConnectionState :: enum VarInt {
    Status = 1,
    Login = 2,
    Transfer = 3,
}

// Namespaced location thing, in the form of `minecraft:thing`, when no namespace is provided, it defaults to `minecraft`.
Identifier :: distinct string

// Only the version.name field should be considered mandatory
// TODO: place json:omitempty tags
StatusResponsePacket :: struct {
    version: struct {
        name: string `json:"name"`,
        protocol: ProtocolVersion `json:"protocol"`,
    },
    players: struct { max: uint, online: uint },
    description: TextComponent,
    favicon: string,
    enforces_secure_chat: bool `json:"enforcesSecureChat"`,
}

PongResponsePacket :: struct {
    payload: Long,
}

LoginSuccessPacket :: distinct GameProfile

// A disconnect packet issued during the configuration state (disconnect resource).
DisconnectConfigurationPacket :: struct {
    reason: TextComponent,
}

TextComponent :: struct {
    text: string `json:"text"`,
}

GameProfile :: struct {
    uuid: uuid.Identifier,
    username: string,
    // FIXME: use some kind of property map? {textures: "value"}
    name: string,
    value: string,
    signature: Maybe(string),
}