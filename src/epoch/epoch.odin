#+vet explicit-allocators
package epoch

import "core:mem"
import "base:intrinsics"

Allocator :: struct {
    // Size of newly allocated blocks, excluding the header size.
    new_block_size: int,
    block_allocator: mem.Allocator,
    // Block pointers returned from `block_allocator`
    pools: [dynamic]rawptr,

    oldest_phys_block: ^BlockHeader,
    // Last node in the linked list of blocks.
    current_logical_block: ^BlockHeader,
    
    oldest_epoch: Epoch,
    current_epoch: Epoch,
}

// Represents a logical block which forms an epoch arena, every BlockHeader starts off as a physical
// block allocated by `block_allocator`, after which it may eventually be split to form a logical block
// that represents data for a certain epoch. Blocks may be merged on freeing and they keep track of the next
// logical and physical block (which may be the same).
BlockHeader :: struct {
    // Usable size of this block excluding the header, may not be the same as new_block_size as this block may be split.
    size: uint,
    used: uint,
    epoch: Epoch,
    // Next logical block in terms of splitting, may be the same as `next_phys` if this block has not been split yet.
    // This next block usually contains data for another epoch (thats why we split it in the first place), or the same
    // one, when we allocated multiple physical blocks for that certain epoch.
    next_logical: ^BlockHeader,
    // Next physically adjacent block obtained from `block_allocator`.
    next_phys: ^BlockHeader,
}

Epoch :: distinct uint

// Inputs:
// 
// - `new_block_size`: size of new physical arena-like blocks, an allocation smaller than or equal to this size
// should always succeed, unless an backing allocator delivers a failure.
init :: proc(alloc: ^Allocator, backing: mem.Allocator, new_block_size: int, loc := #caller_location) {
    assert(new_block_size > 64 /*(arbitrary)*/, "new_block_size too small", loc=loc)
    
    alloc.new_block_size = new_block_size
    alloc.pools.allocator = backing
    alloc.block_allocator = backing
}

destroy :: proc(alloc: Allocator) {
    delete(alloc.pools)
    
    unimplemented()
}

// Ends the previous epoch (if any) and starts a new one.
begin :: proc(alloc: ^Allocator) {}

// Reclaims all memory belonging to the oldest epoch.
relaim_oldest :: proc(alloc: ^Allocator) {
    for block := alloc.oldest_phys_block ;
        block != nil && block.epoch == alloc.oldest_epoch && block.used > 0 ;
        block = block.next_logical {

        block.used = 0
        block.epoch = Epoch(0xdeadbeef)
        
        // check if we can merge with the next logical block
        if block.next_logical != block.next_phys {
            block.next_logical = block.next_logical.next_logical
            block.size += (block.next_logical.size + size_of(BlockHeader))
        }
    }

    if alloc.oldest_epoch < alloc.current_epoch {
        alloc.oldest_epoch += 1
    }
}

allocator :: proc(alloc: ^Allocator) -> mem.Allocator {
    return mem.Allocator {
        _allocator_procedure,
        alloc,
    }
}

@(private="file")
_allocator_procedure :: proc(
    data: rawptr,
    mode: mem.Allocator_Mode,
    size: int,
    align: int,
    old_mem: rawptr,
    old_size: int,
    loc := #caller_location,
) -> ([]u8, mem.Allocator_Error) {
    alloc := cast(^Allocator) data
    
    switch mode {
    case .Alloc:
        bytes, err := _alloc_bytes_non_zeroed(alloc, uint(size), uint(align))
        if err != .None {
            intrinsics.mem_zero(raw_data(bytes), len(bytes))
        }
        return bytes, err
    case .Alloc_Non_Zeroed:
        return _alloc_bytes_non_zeroed(alloc, uint(size), uint(align))
    case .Free:
        return nil, .Mode_Not_Implemented
    case .Free_All:
        return nil, .Mode_Not_Implemented
    case .Resize:
        unimplemented()
    case .Resize_Non_Zeroed:
        unimplemented()
    case .Query_Features:
        set := cast(^mem.Allocator_Mode_Set) old_mem
        set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Query_Features}
    case .Query_Info:
        return nil, .Mode_Not_Implemented
    }
    return nil, .Mode_Not_Implemented
}

@(private="file", require_results)
_alloc_bytes_non_zeroed :: proc(alloc: ^Allocator, size, align: uint) -> (bytes: []u8, err: mem.Allocator_Error) {
    block := alloc.current_logical_block

    if block == nil {
        block = _alloc_block_and_link(alloc) or_return
        block.epoch = alloc.current_epoch
        return _alloc_in_block(block, size, align)
    } 
    if block.epoch != alloc.current_epoch {
        // start new epoch
        block, bytes := _alloc_in_split_or_new_block(alloc, block, size, align) or_return
        block.epoch = alloc.current_epoch
        return bytes, .None
    }

    // try reusing same block, on oom, try in new block
    bytes, err = _alloc_in_block(block, size, align)
    if err == .Out_Of_Memory {
        block = _alloc_block_and_link(alloc) or_return
        block.epoch = alloc.current_epoch
        return _alloc_in_block(block, size, align)
    }
    return bytes, err
}

@(private="file", require_results)
_alloc_in_split_or_new_block :: proc(alloc: ^Allocator, to_split: ^BlockHeader, size, align: uint) -> (block: ^BlockHeader, bytes: []u8, err: mem.Allocator_Error) {
    // compute padded size
    split_base := _block_data_ptr(to_split) + uintptr(to_split.used)
    header_addr := mem.align_forward_uintptr(split_base, align_of(BlockHeader))
    payload_addr := mem.align_forward_uintptr(header_addr + size_of(BlockHeader), uintptr(align))
    required_size := uint(payload_addr - split_base) + size

    if can_split := to_split.used + required_size <= to_split.size; !can_split {
        block := _alloc_block_and_link(alloc) or_return
        return block, _alloc_in_block(block, size, align)
    }

    // split
    new_block := cast(^BlockHeader) rawptr(header_addr)
    mem.zero(new_block, size_of(BlockHeader))
    new_block.size = to_split.size - to_split.used - required_size

    to_split.size -= required_size
    assert(to_split.next_logical == nil)
    to_split.next_logical = new_block

    bytes = mem.byte_slice(rawptr(payload_addr), size)
    return new_block, bytes, .None
}

// Allocates a new block and updates allocator block pointers and links.
@(private="file")
_alloc_block_and_link :: proc(alloc: ^Allocator) -> (hdr: ^BlockHeader, err: mem.Allocator_Error) {
    alloc_size := alloc.new_block_size + size_of(BlockHeader)

    block_bytes := mem.alloc_bytes_non_zeroed(alloc_size, align_of(BlockHeader), alloc.block_allocator) or_return
    defer if err != .None {
        _ = mem.free_bytes(block_bytes, alloc.block_allocator)
    }
    append(&alloc.pools, raw_data(block_bytes)) or_return

    hdr = cast(^BlockHeader) raw_data(block_bytes)
    mem.zero(hdr, size_of(BlockHeader))
    hdr.size = uint(alloc.new_block_size)

    if prev := alloc.current_logical_block; prev != nil {
        // TODO: are we sure about this, if we free an epoch, we may not want to free the allocated blocks
        assert(prev.next_phys == nil)
        assert(prev.next_logical == nil, "current logical block, but it has a next one??")
        prev.next_phys = hdr
        prev.next_logical = hdr
    } else {
        // first allocation, block pointers are nil
        assert(alloc.oldest_phys_block == nil)
        alloc.oldest_phys_block = hdr
        alloc.current_logical_block = hdr
    }
    return hdr, .None
}

@(private="file", require_results)
_alloc_in_block :: proc(block: ^BlockHeader, size, align: uint) -> ([]u8, mem.Allocator_Error) {
    start_addr := _block_data_ptr(block) + uintptr(block.used)
    aligned_addr := mem.align_forward_uintptr(start_addr, uintptr(align))
    required_size := uint(aligned_addr - start_addr) + size
    
    if block.used + required_size > block.size {
        return nil, .Out_Of_Memory
    }

    block.size += required_size
    return mem.byte_slice(rawptr(aligned_addr), size), .None
}

@(private="file")
_block_data_ptr :: #force_inline proc "contextless" (block: ^BlockHeader) -> uintptr {
    return uintptr(block) + size_of(BlockHeader)
}