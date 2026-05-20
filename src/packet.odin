package crux

import "core:reflect"
import "base:intrinsics"
import "core:encoding/uuid"

@(private="file")
LOG2 :: intrinsics.constant_log2

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
    KnownPacksPacket,
    AcknowledgeFinishConfigurationPacket,
    // sent in .Play state
    ClientTickEndPacket,
    SetPlayerRotationPacket,
    SetPlayerPositionPacket,
    SetPlayerPositionRotationPacket,
    ConfirmTeleportationPacket,
    PlayerLoadedPacket,
    KeepAlivePlayPacket,
    SwingArmPacket,
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
    
    // sent in .Configuration state
    
    PluginMessage       = 0x02,
    ClientInformation   = 0x00,
    KnownPacks          = 0x07,
    AcknowledgeFinishConfiguration = 0x03,
    
    // sent in .Play state
    
    ClientTickEnd             = 0x0c,
    SetPlayerRotation         = 0x1f,
    SetPlayerPosition         = 0x1d,
    SetPlayerPositionRotation = 0x1e,
    ConfirmTeleportation      = 0x00,
    PlayerLoaded              = 0x2b,
    KeepAlivePlay             = 0x1b,
    SwingArm                  = 0x3c,
}

ClientBoundPacket :: union #no_nil {
    // sent in .Status state
    StatusResponsePacket,
    PongResponsePacket,
    // sent in .Login state
    LoginSuccessPacket,
    // sent in .Configuration satte
    PluginMessagePacket,
    DisconnectConfigurationPacket,
    KnownPacksPacket,
    RegistryDataPacket,
    FinishConfigurationPacket,
    // sent in .Play state
    LoginPacket,
    DisconnectPlayPacket,
    SynchronizePlayerPositionPacket,
    PlayerInfoUpdatePacket,
    GameEventPacket,
    PlayerAbilitiesPacket,
    KeepAlivePlayPacket,
}

ClientBoundPacketId :: enum VarInt {
    // sent in Status state
    
    StatusResponse = 0x00,
    PongResponse   = 0x01,
    
    // sent in Login state
    
    LoginSuccess   = 0x02,
    
    // sent in Configuration state

    PluginMessage           = 0x01,
    DisconnectConfiguration = 0x02,
    KnownPacks              = 0x0e,
    RegistryData            = 0x07,
    FinishConfiguration     = 0x03,

    // sent in Play state

    Login                     = 0x30,
    DisconnectPlay            = 0x20,
    SynchronizePlayerPosition = 0x46,
    PlayerInfoUpdate          = 0x44,
    GameEvent                 = 0x26,
    PlayerAbilities           = 0x3e,
    KeepAlivePlay             = 0x2b,
}

@(private)
get_clientbound_packet_descriptor :: proc(packet: ClientBoundPacket) -> ClientBoundPacketDescriptor {
    tag: i64 = reflect.get_union_variant_raw_tag(packet)
    #no_bounds_check return clientbound_packet_descriptors[tag]
}

@(private="file")
VARIANT_IDX_OF :: intrinsics.type_variant_index_of

// mapping of ClientBoundPacket raw union tags to packet ids
// IMPORTANT NOTE: ClientBoundPacket must be #no_nil or we need a +1 on the variant idx
@(rodata, private="file")
clientbound_packet_descriptors := [intrinsics.type_union_variant_count(ClientBoundPacket)]ClientBoundPacketDescriptor {
    // sent in Status state
    VARIANT_IDX_OF(ClientBoundPacket, StatusResponsePacket)            = { .StatusResponse,            false },
    VARIANT_IDX_OF(ClientBoundPacket, PongResponsePacket)              = { .PongResponse,              true  },
    // sent in Login state
    VARIANT_IDX_OF(ClientBoundPacket, LoginSuccessPacket)              = { .LoginSuccess,              false },
    // sent in Configuration state
    VARIANT_IDX_OF(ClientBoundPacket, PluginMessagePacket)             = { .PluginMessage,             false },
    VARIANT_IDX_OF(ClientBoundPacket, DisconnectConfigurationPacket)   = { .DisconnectConfiguration,   true  },
    VARIANT_IDX_OF(ClientBoundPacket, KnownPacksPacket)                = { .KnownPacks,                false },
    VARIANT_IDX_OF(ClientBoundPacket, RegistryDataPacket)              = { .RegistryData,              false },
    VARIANT_IDX_OF(ClientBoundPacket, FinishConfigurationPacket)       = { .FinishConfiguration,       false },
    // sent in Play state
    VARIANT_IDX_OF(ClientBoundPacket, LoginPacket)                     = { .Login,                     false },
    VARIANT_IDX_OF(ClientBoundPacket, DisconnectPlayPacket)            = { .DisconnectPlay,            true  },
    VARIANT_IDX_OF(ClientBoundPacket, SynchronizePlayerPositionPacket) = { .SynchronizePlayerPosition, false },
    VARIANT_IDX_OF(ClientBoundPacket, PlayerInfoUpdatePacket)          = { .PlayerInfoUpdate,          false },
    VARIANT_IDX_OF(ClientBoundPacket, GameEventPacket)                 = { .GameEvent,                 false },
    VARIANT_IDX_OF(ClientBoundPacket, PlayerAbilitiesPacket)           = { .PlayerAbilities,           false },
    VARIANT_IDX_OF(ClientBoundPacket, KeepAlivePlayPacket)             = { .KeepAlivePlay,             false },
}

@(private)
get_serverbound_packet_descriptor :: proc(packet: ServerBoundPacket) -> ServerBoundPacketDescriptor {
    tag: i64 = reflect.get_union_variant_raw_tag(packet)
    #no_bounds_check return serverbound_packet_descriptors[tag]
}

// IMPORTANT NOTE: ServerBoundPacket must be #no_nil or we need a +1 on the variant idx
@(rodata, private="file")
serverbound_packet_descriptors := [intrinsics.type_union_variant_count(ServerBoundPacket)]ServerBoundPacketDescriptor {
    // TODO: is this packet allowed in multiple states?
    // TODO: make expected_client_state Maybe(ClientState) (this can be a constant since around 19/09 as Maybe has only one variant); wait for release dev-10
    VARIANT_IDX_OF(ServerBoundPacket, LegacyServerListPingPacket)           = { .Handshake },
    VARIANT_IDX_OF(ServerBoundPacket, HandshakePacket)                      = { .Handshake },
    VARIANT_IDX_OF(ServerBoundPacket, StatusRequestPacket)                  = { .Status },
    VARIANT_IDX_OF(ServerBoundPacket, PingRequestPacket)                    = { .Status },
    VARIANT_IDX_OF(ServerBoundPacket, LoginStartPacket)                     = { .Login },
    VARIANT_IDX_OF(ServerBoundPacket, LoginAcknowledgedPacket)              = { .Login },
    VARIANT_IDX_OF(ServerBoundPacket, PluginMessagePacket)                  = { .Configuration },
    VARIANT_IDX_OF(ServerBoundPacket, ClientInformationPacket)              = { .Configuration },
    VARIANT_IDX_OF(ServerBoundPacket, KnownPacksPacket)                     = { .Configuration },
    VARIANT_IDX_OF(ServerBoundPacket, AcknowledgeFinishConfigurationPacket) = { .Configuration },
    VARIANT_IDX_OF(ServerBoundPacket, ClientTickEndPacket)                  = { .Play },
    VARIANT_IDX_OF(ServerBoundPacket, SetPlayerRotationPacket)              = { .Play },
    VARIANT_IDX_OF(ServerBoundPacket, SetPlayerPositionPacket)              = { .Play },
    VARIANT_IDX_OF(ServerBoundPacket, SetPlayerPositionRotationPacket)      = { .Play },
    VARIANT_IDX_OF(ServerBoundPacket, ConfirmTeleportationPacket)           = { .Play },
    VARIANT_IDX_OF(ServerBoundPacket, PlayerLoadedPacket)                   = { .Play },
    VARIANT_IDX_OF(ServerBoundPacket, KeepAlivePlayPacket)                  = { .Play },
    VARIANT_IDX_OF(ServerBoundPacket, SwingArmPacket)                       = { .Play },
}

@(private)
ClientBoundPacketDescriptor :: struct {
    packet_id: ClientBoundPacketId,
    // Whether the `ClientConnection` sending this packet will enter a terminating state.
    is_terminal: bool,
}

@(private)
ServerBoundPacketDescriptor :: struct {
    // Client state in which this packet should arrive.
    expected_client_state: ClientState,
}

// ---------------------------------------- 
// Handshake phase related packets
// ---------------------------------------- 

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

// ---------------------------------------- 
// Status phase related packets
// ---------------------------------------- 

StatusRequestPacket :: struct {}

PingRequestPacket :: struct {
    payload: Long,
}

// ---------------------------------------- 
// Login phase related packets
// ---------------------------------------- 

LoginStartPacket :: struct {
    username: string /*(16)*/,
    uuid: uuid.Identifier,
}

LoginAcknowledgedPacket :: struct {}

// ---------------------------------------- 
// Configuration phase related packets
// ---------------------------------------- 

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

KnownPacksPacket :: struct {
    known_packs: []KnownPack,
}

KnownPack :: struct {
    namespace: string,
    id: string,
    version: string,
}

AcknowledgeFinishConfigurationPacket :: struct {}

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

LoginSuccessPacket :: struct {
    game_profile: GameProfile,
}

// A disconnect packet issued during the configuration state (disconnect resource).
DisconnectConfigurationPacket :: struct {
    reason: TextComponent,
}

RegistryDataPacket :: union #no_nil {
    DimensionTypeRegistry,
    CatVariantRegistry,
    ChickenVariantRegistry,
    CowVariantRegistry,
    FrogVariantRegistry,
    PigVariantRegistry,
    WolfVariantRegistry,
    WolfSoundVariantRegistry,
    PaintingVariantRegistry,
    DamageTypeRegistry,
    BiomeRegistry,
}

PaintingVariantRegistry :: Registry(PaintingVariant)
PaintingVariant :: struct {
    asset_id: Identifier,
    width: u8,
    height: u8,
    title: TextComponent,
    author: TextComponent,
}

Registry :: struct($E: typeid) {
    entries: []RegistryEntry(E),
}

RegistryEntry :: struct($E: typeid) {
    id: Identifier,
    data: Maybe(E),
}

DimensionTypeRegistry :: Registry(DimensionType)
DimensionType :: struct {
    has_skylight: bool,
    has_ceiling: bool,
    has_ender_dragon_fight: bool,
    has_fixed_time: bool,
    monster_spawn_light_level: u8,
    monster_spawn_block_light_limit: u8,
    skybox: Skybox,
    cardinal_light: CardinalLight,
    coordinate_scale: f64,
    ambient_light: f32,
    logical_height: u16,
    min_y: i16,
    height: u16,
    infiniburn: BlockTag,
    // TODO: attributes: map[AttributeId]..
    default_clock: Maybe(WorldClock),
    timelines: []Identifier,
}

Skybox :: enum u8 { Overworld = 0, End, None }
CardinalLight :: enum u8 { Default = 0, Nether }

skybox_to_string :: proc(s: Skybox) -> string {
    switch s {
    case .Overworld: return "overworld"
    case .End: return "end"
    case .None: return "none"
    case: unreachable()
    }
}

cardinal_light_to_string :: proc(c: CardinalLight) -> string {
    switch c {
    case .Default: return "default"
    case .Nether: return "nether"
    case: unreachable()
    }
}

@(rodata)
overworld_dimension_descriptor := DimensionType {
    has_skylight = true,
    has_ceiling = false,
    has_ender_dragon_fight = false,
    coordinate_scale = 1.0,
    has_fixed_time = false,
    ambient_light = 0.0,
    min_y = -64,
    height = 384,
    logical_height = 384,
    monster_spawn_light_level = 7,
    monster_spawn_block_light_limit = 7,
    infiniburn = BlockTag("#infiniburn_overworld"),
    skybox = .Overworld,
    cardinal_light = .Default,
    default_clock = WorldClock("minecraft:overworld"),
}

// A block tag starting with '#', e.g. #infiniburn_end
BlockTag :: distinct string

// By default, there are two world clocks, named `minecraft:overworld` and `minecraft:the_end`
WorldClock :: distinct string

CatVariantRegistry :: Registry(CatVariant)
CatVariant :: struct {
    using _: MobVariantBase,
    baby_asset_id: Identifier,
}

ChickenVariantRegistry :: Registry(ChickenVariant)
ChickenVariant :: struct {
    using _: MobVariantBase,
    baby_asset_id: Identifier,
    model: enum { Normal = 0, Cold },
}

CowVariantRegistry :: Registry(CowVariant)
CowVariant :: struct {
    using _: MobVariantBase,
    baby_asset_id: Identifier,
    model: enum { Normal = 0, Cold, Warm },
}

FrogVariantRegistry :: Registry(FrogVariant)
FrogVariant :: MobVariantBase

PigVariantRegistry :: Registry(PigVariant)
PigVariant :: struct {
    using _: MobVariantBase,
    baby_asset_id: Identifier,
    model: enum { Normal = 0, Cold },
}

WolfVariantRegistry :: Registry(WolfVariant)
WolfVariant :: struct {
    assets, baby_assets: struct {
        angry: Identifier,
        wild: Identifier,
        tame: Identifier,
    },
}

WolfSoundVariantRegistry :: Registry(WolfSoundVariant)
WolfSoundVariant :: struct {
    // FIXME: should actually be sound events (identifier or {sound_id, range:F})
    adult_sounds, baby_sounds: struct {
        ambient_sound: Identifier,
        death_sound: Identifier,
        growl_sound: Identifier,
        hurt_sound: Identifier,
        pant_sound: Identifier,
        whine_sound: Identifier,
    },
}

MobVariantBase :: struct {
    asset_id: Identifier,
    spawn_conditions: []SpawnCondition,
}

SpawnCondition :: struct {
    priority: i32,
    condition: Maybe(SpawnConditionMatch),
}

SpawnConditionMatch :: union {
    SpawnConditionBiomeMatch,
    SpawnConditionStructureMatch,
    SpawnConditionMoonBrightnessMatch,
}

SpawnConditionBiomeMatch :: struct {
    biomes: []Identifier,
}

SpawnConditionStructureMatch :: struct {
    structures: []Identifier,
}

SpawnConditionMoonBrightnessMatch :: struct {
    // Both fields may have the same value in order to specify a single brightness value.
    min: f32,
    max: f32,
}

DamageTypeRegistry :: Registry(DamageType)
DamageType :: struct {
    message_id: Identifier,
    exhaustion: f32,
    scaling: enum { Never, Always, WhenCausedByLivingNonPlayer },
    effects: enum { Hurt = 0, Thorns, Drowning, Burning, Poking, Freezing },
    death_message_type: enum { Default = 0, FallVariants, IntentionalGameDesign },
}

BiomeRegistry :: Registry(Biome)
Biome :: struct {
    has_precipitation: bool,
    temperature: f32,
    temperature_modifier: enum { None = 0, Frozen },
    downfall: f32,
    effects: struct {
        water_color: i32,
        foliage_color: i32,
        dry_foliage_color: i32,
        grass_color: Maybe(i32),
        grass_color_modifier: enum { None = 0, DarkForest, Swamp },
    },
    // TODO: map[string] for environment attributes (optional)
    carvers: []Identifier,
    features: []Tag,
    creature_spawn_probability: Maybe(f32),
    // spawners: 
}

// Tag starting with #
Tag :: distinct string

FinishConfigurationPacket :: struct {}

GameProfile :: struct {
    // contains multiple multiple properties in theory, but we (and the vanilla client) only ever sends one
    using _: Property,
    uuid: uuid.Identifier,
    username: string,
}

// Key-value pair, optionally signed
Property :: struct {
    name: string /*(64)*/,
    value: string /*(32767)*/,
    signature: Maybe(string) /*(1024)*/,
}

// ---------------------------------------- 
//  Play phase related packets
// ---------------------------------------- 

LoginPacket :: struct {
    entity_id: i32,
    is_hardcore: bool,
    dimension_names: []Identifier,
    max_players: VarInt,
    view_distance: VarInt,
    simulation_distance: VarInt,
    reduced_debug_info: bool,
    enable_respawn_screen: bool,
    do_limited_crafting: bool,
    dimension_type: VarInt,
    dimension_name: Identifier,
    hashed_seed: Long,
    gamemode: GameMode,
    prev_gamemode: Maybe(GameMode),
    is_debug: bool,
    is_flat: bool,
    death_location: Maybe(struct {
        location: Position,
        dimension_name: Identifier,
    }),
    portal_cooldown: VarInt,
    sea_level: VarInt,
    enforces_secure_chat: bool,
}

GameMode :: enum {
    Survival  = 0,
    Creative  = 1,
    Adventure = 2,
    Spectator = 3,
}

DisconnectPlayPacket :: struct {
    reason: TextComponent,
}

SynchronizePlayerPositionPacket :: struct {
    teleport_id: VarInt,
    x: f64,
    y: f64,
    z: f64,
    velocity_x: f64,
    velocity_y: f64,
    velocity_z: f64,
    yaw: f32,
    pitch: f32,
    flags: TeleportFlags,
}

TeleportFlags :: bit_set[TeleportFlag; u32]
TeleportFlag :: enum {
    RelativeX         = LOG2(0x0001),
    RelativeY         = LOG2(0x0002),
    RelativeZ         = LOG2(0x0004),
    RelativeYaw       = LOG2(0x0008),
    RelativePitch     = LOG2(0x0010),
    RelativeVelocityX = LOG2(0x0020),
    RelativeVelocityY = LOG2(0x0040),
    RelativeVelocityZ = LOG2(0x0080),
    RotateVelocity    = LOG2(0x100),
}

ClientTickEndPacket :: struct {}

SetPlayerRotationPacket :: struct {
    yaw: f32,
    pitch: f32,
    // TODO: change to bitfield and fix decoding invalid values
    flags: u8,
}

SetPlayerPositionPacket :: struct {
    x: f64,
    feet_y: f64,
    z: f64,
    // TODO: change to bitfield and fix decoding invalid values
    flags: u8,
}

SetPlayerPositionRotationPacket :: struct {
    x: f64,
    feet_y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
    // TODO: change to bitfield and fix decoding invalid values
    flags: u8,
}

ConfirmTeleportationPacket :: struct {
    teleport_id: VarInt,
}

PlayerLoadedPacket :: struct {}

SwingArmPacket :: struct {
    hand: Hand,
}
Hand :: enum { MainHand = 0, OffHand = 1 }

PlayerAbilityFlags :: bit_set[PlayerAbilityFlag; u8]
PlayerAbilityFlag :: enum {
    Invulnerable = LOG2(0x01),
    Flying       = LOG2(0x02),
    AllowFlying  = LOG2(0x04),
    CreativeMode = LOG2(0x08),
}

PlayerInfoUpdatePacket :: struct {
    // TODO: replace with []ServerPlayer source of truth and place bitset back in
    players: []PlayerInfoUpdateEntry,
}

PlayerInfoUpdateEntry :: struct {
    uuid: uuid.Identifier,
    actions: []PlayerInfoUpdateAction,
}

PlayerInfoUpdateAction :: union {
    PlayerInfoUpdateActionAddPlayer,
    PlayerInfoUpdateActionUpdateGameMode,
    PlayerInfoUpdateActionUpdateListed,
    // TODO: add remaining actions
}

PlayerInfoUpdateActionAddPlayer :: struct {
    username: string /*(16)*/,
    // Properties included in this packet are the same as in LoginSuccessPacket,
    properties: []Property,
}

PlayerInfoUpdateActionUpdateGameMode :: struct {
    new_mode: GameMode,
}

PlayerInfoUpdateActionUpdateListed :: struct {
    // Whether the player should be listed on the tab list.
    listed: bool,
}

GameEventPacket :: union {
    NoRespawnBlockAvailable,
    BeginRaining,
    EndRaining,
    ChangeGameMode,
    WinGame,
    DemoEvent,
    ArrowHitPlayer,
    RainLevelChange,
    ThunderLevelChange,
    PlayPufferfishStingSound,
    PlayElderGuardianAppearance,
    EnableRespawnScreen,
    SetLimitedCrafting,
    StartWaitingForChunks,
}

NoRespawnBlockAvailable :: struct {}

BeginRaining :: struct {}

EndRaining :: struct {}

ChangeGameMode :: struct {
    new_mode: GameMode,
}

WinGame :: enum {
    Respawn           = 0,
    CreditsAndRespawn = 1,
}

DemoEvent :: enum {
    ShowWelcome       = 0,
    MovementControls  = 101,
    JumpControls      = 102,
    InventoryControls = 103,
    DemoEnd           = 104,
}

ArrowHitPlayer :: struct {}

RainLevelChange :: struct {
    level: f32,
}

ThunderLevelChange :: struct {
    level: f32,
}

PlayPufferfishStingSound :: struct {}

PlayElderGuardianAppearance :: struct {}

EnableRespawnScreen :: enum {
    Enable,
    RespawnImmediately,
}

SetLimitedCrafting :: enum {
    Disable = 0,
    Enable  = 1,
}

StartWaitingForChunks :: struct {}

PlayerAbilitiesPacket :: struct {
    flags: PlayerAbilityFlags,
    flying_speed: f32,
    fov_modifier: f32,
}

KeepAlivePlayPacket :: struct {
    id: Long,
}

Position :: bit_field i64be {
    x: i32be | 26,
    z: i32be | 26,
    y: i16be | 12,
}
