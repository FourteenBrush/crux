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
    block_states: PalettedContainer(BlockId) `fmt:"-"`,
    biomes: PalettedContainer(BiomeId) `fmt:"-"`,
}

PalettedContainer :: struct($Id: typeid) where Id == BlockId || Id == BiomeId {
    // Possible values: 0 (single valued, data array empty), 4-8 (indirect), 15 (direct).
    // TODO: those values should be dynamically calculated based on the size of the global block state
    // and biome palettes (injected through data packs).
    bits_per_entry: u8,
    // Nil when bits_per_entry is 15 (direct).
    palette: union #no_nil {
        Id,
        // Palette entries, the paletted container data are indices into this array.
        []i32,
    },
    // Nil when bits_per_entry is 0.
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

BlockId :: enum i16 {
    Air   = 0,
    Stone = 1,
    Grass = 9,
    Dirt  = 10,
    GoldBlock = 2137,
}

BiomeId :: enum {
   Plains = 0, 
}

create_chunk_section :: proc(block: BlockId) -> (section: ChunkSection) {
    section.block_count = block == .Air ? 0 : BLOCKS_PER_CHUNK_SECTION
    section.block_states.bits_per_entry = 0
    section.block_states.palette = block
    
    section.biomes.bits_per_entry = 0
    section.biomes.palette = .Plains
    return
}

serialize_paletted_container :: proc(outb: ^NetworkBuffer, container: PalettedContainer($Id)) {
    buf_write_byte(outb, container.bits_per_entry)
    
    when Id == BlockId {
        switch container.bits_per_entry {
        case 0:
            assert(container.data == nil, "palette should be nil for single valued format")
            palette := container.palette.(BlockId)
            buf_write_var_int(outb, VarInt(palette))
        case 4..=8:
            assert(container.data != nil, "missing data for indirect palette")
            palette := container.palette.([]i32)
            buf_write_var_int(outb, VarInt(len(palette)))
            for elem in palette {
                buf_write_var_int(outb, VarInt(elem))
            }
            for elem in container.data {
                buf_write_long(outb, elem)
            }
        case 15:
            assert(
                len(container.data) == (BLOCKS_PER_CHUNK_SECTION * int(container.bits_per_entry) + 63) / _BITS_PER_LONG,
                "more section long entries than expected",
            )
            for elem in container.data {
                buf_write_long(outb, elem)
            }
        case:
            panic("unsupported palette bits per entry")
        }
    } else when Id == BiomeId {
        assert(container.bits_per_entry == 0, "TODO: handle biome specific bits per entry")
        palette := container.palette.(BiomeId)
        buf_write_var_int(outb, VarInt(palette))
    } else {
        #panic("unsupported paletted container id")
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