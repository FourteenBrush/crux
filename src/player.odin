package crux

import "core:mem"
import "core:net"
import "core:time"

import "src:items"

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
    contents: []items.ItemStack,
    // Item that we clicked on in the inventory, no the main/offhand held item.
    carried_item: Maybe(items.ItemStack),
    held_item_slot: i16,
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

player_inventory_add_item :: proc(session: ^SessionData, item: items.ItemStack) {
    it := _create_add_item_iterator(&session.inventory, item)
    for slot_nr, item in _add_item_iterator(&it) {
        packet := ContainerSetSlotPacket {
            window_id = 0, // inventory
            state_id = 0,
            slot = slot_nr,
            slot_data = item,
        }
        enqueue_packet(session, packet)
    }
}

PLAYER_INV_MIN_SLOT :: 0
PLAYER_INV_MAX_SLOT :: 45
PLAYER_INV_SLOT_COUNT :: (PLAYER_INV_MAX_SLOT - PLAYER_INV_MIN_SLOT) + 1
#assert(PLAYER_INV_SLOT_COUNT == 46)

@(rodata, private)
INVENTORY_INSERT_ORDER := [36]i16 {
    // try hotbar first
    36, 37, 38, 39, 40, 41, 42, 43, 44,
     9, 10, 11, 12, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31, 32, 33, 34, 35,
}

@(private)
AddItemIterator :: struct {
    inv: ^Inventory,
    to_add: items.ItemStack,
    // Slot index into inventory grid, _not_ slot number.
    last_slot_idx_tried: i16,
}

@(private, require_results)
_create_add_item_iterator :: proc(target: ^Inventory, to_add: items.ItemStack) -> (it: AddItemIterator) {
    it.inv = target
    it.to_add = to_add
    return it
}

@(private)
_add_item_iterator :: proc(it: ^AddItemIterator) -> (slot_nr: i16, item: items.ItemStack, ok: bool) {
    if it.to_add.count == 0 do return
    
    for i in it.last_slot_idx_tried..<len(INVENTORY_INSERT_ORDER) {
        defer it.last_slot_idx_tried += 1

        #no_bounds_check slot_nr := INVENTORY_INSERT_ORDER[i]
        item := &it.inv.contents[slot_nr]

        if item.type != it.to_add.type && item.type != &items.AIR {
            continue
        }

        if item.type == &items.AIR {
            // update material so we are not increasing the count of an air itemstack
            item.type = it.to_add.type
        }

        max_stack_size := item.type.max_stack_size
        if item.count < max_stack_size {
            to_add := min(max_stack_size - item.count, it.to_add.count)
            item.count += to_add
            it.to_add.count -= to_add
            return slot_nr, item^, true
        }
    }
    return -1, item, false
}