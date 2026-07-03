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
    assert(session.state == .Login, "compression may only be configured in login state")
    enqueue_packet(session, SetCompressionPacket { threshold=VarInt(threshold) })
}