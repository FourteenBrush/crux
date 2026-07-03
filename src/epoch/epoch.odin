package epoch

import "base:intrinsics"
import "core:mem"

Allocator :: struct {
    oldest_block: ^BlockHeader,
    current_block: ^BlockHeader,
    // Pointers returned from `block_allocator`
    pools: [dynamic]rawptr,
    
    oldest_epoch: Epoch,
    current_epoch: Epoch,
    new_block_size: int,
    block_allocator: mem.Allocator,
}

// Represents a logical block which forms an epoch arena, every BlockHeader starts off as a physical
// block allocated by `block_allocator`, after which it may eventually be split to form a logical block
// that represents data for a certain epoch. Blocks may be merged on freeing and they keep track the next
// logical and physical block (which may be the same).
BlockHeader :: struct {
    // Usable size of this block excluding the header, to support splitting.
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

init :: proc(alloc: ^Allocator, backing: mem.Allocator, new_block_size: int) {
    assert(new_block_size > 0)
    
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
    for block := alloc.oldest_block; block != nil && block.epoch == alloc.oldest_epoch; block = block.next_logical {
        block.used = 0
        block.epoch = Epoch(0xdeadbeef)

        // check if we can merge with the next logical block
        if block.next_logical != block.next_phys {
            // may be a physical one
            block.next_logical = block.next_logical.next_logical
            block.size += (block.next_logical.size + size_of(BlockHeader))
        }
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
    if alloc.current_block == nil {
        pool_align := max(align_of(BlockHeader), align)
        block := mem.alloc(alloc.new_block_size, int(pool_align), alloc.block_allocator) or_return
        append(&alloc.pools, block) or_return
        
        alloc.current_block = cast(^BlockHeader) block
        alloc.current_block.epoch = alloc.current_epoch
        alloc.oldest_block = alloc.current_block
    }

    current_block := alloc.current_block
    aligned_size := mem.align_forward_uint(size, align)
    // find block of aligned size
    if current_block.used + aligned_size > current_block.size {
        // TODO: consider merging here (or on .Free?)
        
    }

    unimplemented()
}

@(private="file")
_block_data_ptr :: #force_inline proc(block: ^BlockHeader) -> rawptr {
    return rawptr(uintptr(block) + size_of(BlockHeader))
}