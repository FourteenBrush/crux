package crux

import "core:mem"
import "core:net"
import "core:time"

@(private)
SessionData :: struct {
    socket: net.TCP_Socket,
    state: ClientState,
    terminating: bool,
    
    protocol_version: ProtocolVersion,
    // filled in after LoginStartPacket
    game_profile: GameProfile,
    
    pos: Pos,
    yaw: f64,
    pitch: f64,
    pending_teleport: Maybe(PendingTeleport),
    // Whether the player has been added to the world yet
    spawned: bool,
    
    clientbound_keepalive: struct {
        // Zero initialized if we haven't sent any.
        sent: time.Tick,
        id: i64,
        awaiting_serverbound: bool,
    },

    current_breaking_sequence: Maybe(i32),
    #subtype inventory: Inventory,
    
    // TODO: move to global arena list based on epoch, backed by vmem allocator
    packet_scratch_alloc: mem.Allocator,
}

// IMPORTANT NOTE: values must match respective values from HandshakeIntent to allow casting.
// ORDER IS IMPORTANT!!
ClientState :: enum u8 {
    Handshake,
    Status        = auto_cast HandshakeIntent.Status,
    Login         = auto_cast HandshakeIntent.Login,
    Transfer      = auto_cast HandshakeIntent.Transfer,
    Configuration,
    Play,
}
#assert(int(ClientState.Login) <= int(max(HandshakeIntent)))

@(private="file")
PendingTeleport :: struct {
    id: VarInt,
    pos: Pos,
}

Inventory :: struct {
    items: []ItemStack,
}

player_crosses_chunk_borders :: proc(session: ^SessionData, new_pos: Pos) -> bool {
    // TODO: consider caching chunk positions for entities to avoid floor operations
    chunk_pos := pos_to_chunk(session.pos)
    new_chunk_pos := pos_to_chunk(new_pos)
    return chunk_pos != new_chunk_pos
}

player_teleport :: proc(session: ^SessionData, pos: Pos) {
    assert(session.pending_teleport == nil, "TODO: stack player teleports or something")
    enqueue_packet(session, SynchronizePlayerPositionPacket { pos=pos })
    // TODO: pass id based on tick/pos combination
    session.pending_teleport = PendingTeleport { pos=pos }
}

player_set_compression :: proc(session: ^SessionData, threshold: i32) {
    enqueue_packet(session, SetCompressionPacket { threshold=VarInt(threshold) })
}

player_send_keepalive :: proc(session: ^SessionData, id: i64, now: time.Tick) {
    #partial switch session.state {
    case .Configuration:
        enqueue_packet(session, KeepAliveConfigurationPacket { id=Long(id) })
    case .Play:
        enqueue_packet(session, KeepAlivePlayPacket { id=Long(id) })
    }

    session.clientbound_keepalive.id = id
    session.clientbound_keepalive.sent = now
    session.clientbound_keepalive.awaiting_serverbound = true
}

PLAYER_INV_SLOT_COUNT :: 46

@(rodata, private)
INVENTORY_INSERT_ORDER := [36]i16 {
    // try hotbar first
    36, 37, 38, 39, 40, 41, 42, 43, 44,
     9, 10, 11, 12, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31, 32, 33, 34, 35,
}