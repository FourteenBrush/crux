#+vet explicit-allocators
package crux

import "core:mem"
import "core:net"
import "core:time"
import "core:slice"

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

@(private)
_player_initiate_spawning :: proc(session: ^SessionData) {
    assert(!session.spawned, "already spawned")
    
    gamemode_change := PlayerInfoUpdateActionUpdateGameMode {
        new_mode = .Survival,
    }
    add_to_tablist := PlayerInfoUpdateActionUpdateListed { listed=true }
    enqueue_packet(session, PlayerInfoUpdatePacket {
        players = slice.clone([]PlayerInfoUpdateEntry{
            { 
                uuid = session.game_profile.uuid,
                actions = slice.clone([]PlayerInfoUpdateAction{
                    // add_player_action,
                    gamemode_change,
                    add_to_tablist,
                }, session.packet_scratch_alloc),
            },
        }, session.packet_scratch_alloc),
    })
    
    enqueue_packet(session, PlayerAbilitiesPacket {
        flags = {.AllowFlying, .Flying},
        flying_speed = 0.05,
        fov_modifier = 0.1,
    })
    enqueue_packet(session, StartWaitingForChunks {})
    enqueue_packet(session, SetCenterChunkPacket { chunk_pos={0, 0} })

    _player_send_initial_chunks(session, view_distance=VIEW_DISTANCE)
    
    for slot in i16(36)..=44 {
        enqueue_packet(session, ContainerSetSlotPacket {
            window_id = 0,
            state_id = 0,
            slot = slot,
            slot_data = items.ItemStack { count = 64, type = &items.DIRT },
        })
        session.inventory.contents[slot] = items.ItemStack { count = 64, type = &items.DIRT }
    }
}

CENTER_OFFSET :: 4

// Send all chunks for the clients chunk loading area (2 * server view distance + 7 square).
// Seems like the vanilla client displays the outside chunks of the loading area as transparant.
@(private)
_player_send_initial_chunks :: proc(session: ^SessionData, view_distance: int) {
    // center_offset := 2 * view_distance + 3
    center_offset := CENTER_OFFSET

    sections := make([]ChunkSection, OVERWORLD_HEIGHT / CHUNK_SECTION_HEIGHT, session.packet_scratch_alloc)
    for &section, i in sections {
        block_id := i < 8 ? BlockId.Dirt : .Air
        section = create_chunk_section(block_id)
    }
    
    gold_sections := make([]ChunkSection, OVERWORLD_HEIGHT / CHUNK_SECTION_HEIGHT, session.packet_scratch_alloc)
    for &section, i in gold_sections {
        block_id := i < 8 ? BlockId.GoldBlock : .Air
        section = create_chunk_section(block_id)
    }
    
    count := 0
    for x in -center_offset..=center_offset {
        for z in -center_offset..=center_offset {
            chunk_pos := ChunkPos { i32(x), i32(z) }
            sections := sections
            if abs(x) > 2 || abs(z) > 2 {
                _player_send_chunk(session, chunk_pos, .Air)
                continue
            } else if x == 0 && z == 0 {
                sections = gold_sections
            }
            _player_send_chunk_data(session, chunk_pos, sections)
            
            count += 1
        }
    }
}

@(private)
_player_send_chunk :: proc(session: ^SessionData, pos: ChunkPos, block_id: BlockId) {
    // only permit sending new chunks, or replacing existing air chunks
    _, existing_block_id, inserted, _ := map_entry(&get_server().loaded_chunks, pos)
    if !inserted && existing_block_id^ != .Air do return

    existing_block_id^ = block_id
    
    sections := make([]ChunkSection, OVERWORLD_HEIGHT / CHUNK_SECTION_HEIGHT, session.packet_scratch_alloc)
    for &section, i in sections {
        section = create_chunk_section(i < 8 ? block_id : .Air)
    }
    
    enqueue_packet(session, ChunkDataPacket {
        chunk_pos = pos,
        height_maps = nil,
        sections = sections,
        light = {},
    })
}

@(private="file")
_player_send_chunk_data :: proc(session: ^SessionData, pos: ChunkPos, sections: []ChunkSection) {
    assert(len(sections) == OVERWORLD_HEIGHT / CHUNK_SECTION_HEIGHT)
    
    // only permit sending new chunks, or replacing existing air chunks
    _, existing_block_id, inserted, _ := map_entry(&get_server().loaded_chunks, pos)
    if !inserted && existing_block_id^ != .Air do return

    existing_block_id^ = .Grass // just something

    enqueue_packet(session, ChunkDataPacket {
        chunk_pos = pos,
        height_maps = nil,
        sections = sections,
        light = {},
    })
}

player_inventory_add_item :: proc(session: ^SessionData, item: items.ItemStack) {
    it := _create_add_item_iterator(&session.inventory, item, .HotbarFirst)
    for slot_nr, new_item in _add_item_iterator(&it) {
        packet := ContainerSetSlotPacket {
            window_id = 0, // inventory
            state_id = 0,
            slot = slot_nr,
            slot_data = new_item,
        }
        enqueue_packet(session, packet)
    }
}

@(private)
_player_dispatch_container_click :: proc(session: ^SessionData, mode, button: i32, slot: i16) {
    switch ([2]i32{mode, button}) {
    case {0, 0}: // lmb
        if slot == -999 {
            // drop cursor stack
        } else {
            _player_handle_container_lmb_click(&session.inventory, slot)
        }
    case {1, 0}: // shift lmb
        _player_handle_container_shift_lmb_click(session, slot)
    case {0, 1}: // rmb
        if slot == -999 {
            // drop cursor single item
        } else {
            _player_handle_container_rmb_click(&session.inventory, slot)
        }
    }
}

@(private="file")
_player_handle_container_lmb_click :: proc(inv: ^Inventory, slot: i16) {
    // normal click, if carrying item, place it in clicked slot, otherwise start carrying it
    clicked_item := &inv.contents[slot]
    carried_item, is_carrying_item := &inv.carried_item.?

    if !is_carrying_item {
        // if clicking on non air, start carrying that itemstack
        if clicked_item.type != &items.AIR {
            inv.carried_item = clicked_item^
            clicked_item^ = items.ItemStack { type = &items.AIR }
        }
        return
    }

    // try placing item in clicked slot
    if clicked_item.type == carried_item.type {
        // try merging itemstack
        if clicked_item.count < clicked_item.type.max_stack_size {
            // clamp to [0..item_count] to account for item stacks bigger than the max stack size that were somehow obtained
            to_add := clamp(clicked_item.type.max_stack_size - clicked_item.count, 0, carried_item.count)
            clicked_item.count += to_add
            carried_item.count -= to_add
            if carried_item.count == 0 {
                inv.carried_item = nil
            }
        }
    } else {
        // swap carried itemstack with item in that slot
        clicked_item^, inv.carried_item = carried_item^, clicked_item^
        if inv.carried_item.?.type == &items.AIR {
            inv.carried_item = nil
        }
    }
}

// Moves the clicked itemstack (if any) to the first available slot in the inventory, starting from the top left slot downwards.
@(private="file")
_player_handle_container_shift_lmb_click :: proc(session: ^SessionData, slot: i16) {
    inv := &session.inventory
    clicked_item := &inv.contents[slot]
    if clicked_item.type == &items.AIR do return
    
    it := _create_add_item_iterator(inv, clicked_item^, .NoHotbar)
    
    for slot_nr, new_item in _add_item_iterator(&it) {
        enqueue_packet(session, ContainerSetSlotPacket {
            window_id = 0,
            state_id = 0,
            slot = slot_nr,
            slot_data = new_item,
        })
    }
    
    remaining, has_remaining := _add_item_iterator_remaining(it)
    clicked_item^ = has_remaining ? remaining : items.ItemStack { count=0, type=&items.AIR }
}

// Right mouse button click with a carried item attempts to add one to the clicked slot (if the same materials),
// if not the same material, it simply swaps the carried item with the contents of that clicked slot.
// When no item is carried, we start carrying half the amount of items from that slot (ceiled), and leave the rest in there.
@(private="file")
_player_handle_container_rmb_click :: proc(inv: ^Inventory, slot: i16) {
    clicked_item := &inv.contents[slot]
    carried_item, is_carrying_item := &inv.carried_item.?
    
    if !is_carrying_item {
        if clicked_item.type != &items.AIR {
            remaining_count := clicked_item.count / 2 // floored by int div, also handles item count of 1
            inv.carried_item = items.ItemStack { count=clicked_item.count - remaining_count, type=clicked_item.type }
            clicked_item.count = remaining_count
            if clicked_item.count == 0 {
                clicked_item.type = &items.AIR
            }
        }
        return
    }
    
    // clicked same material, add one or do nothing
    if clicked_item.type == carried_item.type {
        if clicked_item.count >= clicked_item.type.max_stack_size do return
        
        clicked_item.count += 1
        carried_item.count -= 1
        if carried_item.count == 0 {
            inv.carried_item = nil
        }
        return
    }
    
    // clicking air, add one to clicked slot
    if clicked_item.type == &items.AIR {
        clicked_item^ = items.ItemStack { count=1, type=carried_item.type }
        carried_item.count -= 1
        if carried_item.count == 0 {
            inv.carried_item = nil
        }
        return
    }
    
    // swap
    inv.carried_item, clicked_item^ = clicked_item^, carried_item^
}

PLAYER_INV_MIN_SLOT :: 0
PLAYER_INV_MAX_SLOT :: 45
PLAYER_INV_SLOT_COUNT :: (PLAYER_INV_MAX_SLOT - PLAYER_INV_MIN_SLOT) + 1
#assert(PLAYER_INV_SLOT_COUNT == 46)

@(rodata, private="file")
INVENTORY_INSERT_ORDER_HOTBAR_FIRST := []i16 {
    // hotbar
    36, 37, 38, 39, 40, 41, 42, 43, 44,
     9, 10, 11, 12, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31, 32, 33, 34, 35,
}
@(rodata, private="file")
INVENTORY_INSERT_ORDER_NO_HOTBAR := []i16 {
    9, 10, 11, 12, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31, 32, 33, 34, 35,
}

@(private="file")
AddItemIterator :: struct {
    inv: ^Inventory,
    to_add: items.ItemStack,
    insert_order: []i16,
    // Slot index into insert order, _not_ slot number.
    last_slot_idx_tried: int,
}

@(private="file")
AddItemIteratorInsertOrder :: enum {
    // Consider adding items to the hotbar slots first, then move to the actual inventory.
    HotbarFirst,
    NoHotbar,
}

@(private, require_results)
_create_add_item_iterator :: proc(target: ^Inventory, to_add: items.ItemStack, insert_order: AddItemIteratorInsertOrder) -> (it: AddItemIterator) {
    it.inv = target
    it.to_add = to_add
    switch insert_order {
    case .HotbarFirst:
        it.insert_order = INVENTORY_INSERT_ORDER_HOTBAR_FIRST
    case .NoHotbar:
        it.insert_order = INVENTORY_INSERT_ORDER_NO_HOTBAR
    case:
        panic("unknown insert order")
    }
    return it
}

@(private="file")
_add_item_iterator :: proc(it: ^AddItemIterator) -> (slot_nr: i16, new_item: items.ItemStack, ok: bool) {
    if it.to_add.count == 0 do return
    
    for ; it.last_slot_idx_tried < len(it.insert_order); it.last_slot_idx_tried += 1 {
        slot_nr = it.insert_order[it.last_slot_idx_tried]
        inv_item := &it.inv.contents[slot_nr]

        if !items.can_merge_into(it.to_add, inv_item^) do continue

        if inv_item.type == &items.AIR {
            // update material so we are not increasing the count of an air itemstack
            inv_item.type = it.to_add.type
        }

        max_stack_size := inv_item.type.max_stack_size
        if inv_item.count < max_stack_size {
            to_add := min(max_stack_size - inv_item.count, it.to_add.count)
            inv_item.count += to_add
            it.to_add.count -= to_add
            return slot_nr, inv_item^, true
        }
    }
    return -1, {}, false
}

@(private="file", require_results)
_add_item_iterator_remaining :: proc(it: AddItemIterator) -> (remaining: items.ItemStack, has_remaining: bool) {
    if it.to_add.count == 0 do return
    return it.to_add, true
}