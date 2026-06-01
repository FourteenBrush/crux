package crux

import "core:mem"

BLOCKS_PER_CHUNK_SECTION :: 16 * 16 * 16 // 4096
CHUNK_SECTION_HEIGHT :: 16

HeightMap :: struct {
    type: HeightMapType,
    data: []Long,
}

HeightMapType :: enum VarInt {
    WorldSurface           = 1,
    MotionBlocking         = 4,
    MotionBlockingNoLeaves = 5,
}

ChunkSection :: struct {
    block_count: i16,
    block_states: PalettedContainer,
    biomes: PalettedContainer,
}

PalettedContainer :: struct {
    // Possible values: 0 (single valued, data array empty), 4-8 (indirect), 15 (direct).
    bits_per_entry: u8,
    palette: VarInt,
    data: []Long,
}

LightData :: struct {
    // Contains bits for each chunk section in the world + 2, each bit indicates that the section
    // has data in the sky light array below.
    // The number of bits that corresponds to chunk sections can be calculated from the world height
    // divided by the height of a chunk column + 2 (for the sections below and above the world height).
    // LSB corresponds to the chunk section below the world height, while MSB covers the section above the world height.
    sky_light_mask: Long,
    block_light_mask: Long,
    empty_sky_light_mask: Long,
    empty_block_light_mask: Long,
    // One array for each bit set to true in the sky light mask, starting with the lowest value,
    // half a byte per light value.
    sky_light: [][2048]u8,
    // One array for each bit set to true in the block light mask, starting with the lowest value,
    // half a byte per light value.
    block_light: [][2048]u8,
}

BlockId :: enum {
    Air  = 0,
    Dirt = 9,
}

BiomeId :: enum {
   Plains, 
}

create_mock_chunk_section :: proc() -> (section: ChunkSection) {
    section.block_count = BLOCKS_PER_CHUNK_SECTION
    section.block_states.bits_per_entry = 0
    section.block_states.palette = VarInt(BlockId.Dirt)
    
    section.biomes.bits_per_entry = 0
    section.biomes.palette = VarInt(BiomeId.Plains)
    return
}

serialize_paletted_container :: proc(outb: ^NetworkBuffer, container: PalettedContainer) {
    buf_write_byte(outb, container.bits_per_entry)
    switch container.bits_per_entry {
    case 0:
        buf_write_var_int(outb, container.palette)
    case 4..=8:
    case 15:
    case:
        unimplemented("handle paletted container bits per entry")
    }
}

@(private="file")
PackedBitArray :: struct {
    data: [dynamic]Long,
    // Number of longs in use.
    count: int,
    // Offset into long, > 0 when entry_bits can be written without crossing boundary.
    bit_idx: u16,
    unit_size: u16,
}

// TODO: pass length and change to []Long
@(private="file")
_create_bit_array :: proc(unit_size: u16, allocator: mem.Allocator) -> (arr: PackedBitArray) {
    assert(unit_size < _BITS_PER_LONG)
    arr.data = make([dynamic]Long, 0, 16, allocator)
    arr.unit_size = unit_size
    append(&arr.data, Long(0))
    return
}

@(private="file")
_BITS_PER_LONG :: size_of(Long) * 8

@(private="file")
_bit_array_push :: proc(arr: ^PackedBitArray, val: u16) #no_bounds_check {
    if arr.bit_idx + arr.unit_size > _BITS_PER_LONG {
        append(&arr.data, Long(0))
        arr.bit_idx = 0
    }
    block := &arr.data[len(arr.data) - 1]
    mask := (Long(1) << arr.unit_size) - 1
    block^ |= (Long(val) & mask) << arr.bit_idx
    
    arr.bit_idx += arr.unit_size
    arr.count += 1
}