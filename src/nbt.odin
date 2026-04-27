package crux

NBTWriter :: struct {
    #subtype buf: ^NetworkBuffer,
    // TOOD: stack of contexts (i64 or something, and impose max nesting)
    inside_compound: bool,
}

@(private="file")
EXPECTED_COMPOUND :: "Incorrect nbt_write_* usage, expected to be inside a compound tag while writing this named tag"

@(private="file")
MAX_STRING_LENGTH :: int(max(u16))

NBTTag :: enum u8 {
    End       = 0,
    Byte      = 1,
    Short     = 2,
    Int       = 3,
    Long      = 4,
    Float     = 5,
    Double    = 6,
    ByteArray = 7,
    String    = 8,
    List      = 9,
    Compound  = 10,
    IntArray  = 11,
    LongArray = 12,
}

@(require_results)
nbt_write_string :: proc(w: ^NBTWriter, str: string) -> WriteError {
    if len(str) > MAX_STRING_LENGTH {
        return .StringTooLong
    } 
    buf_write_byte(w, u8(NBTTag.String))
    buf_write_u16(w, u16(len(str)))
    buf_write_bytes(w, transmute([]u8)str)
    return .None
}

nbt_write_compound_start :: proc(w: ^NBTWriter) {
    buf_write_byte(w, u8(NBTTag.Compound))
    w.inside_compound = true
}

nbt_write_compound_end :: proc(w: ^NBTWriter) {
    assert(w.inside_compound, EXPECTED_COMPOUND)
    buf_write_byte(w, u8(NBTTag.End))
    w.inside_compound = false
}

@(require_results)
nbt_write_named_string :: proc(w: ^NBTWriter, name: string, str: string) -> WriteError {
    if len(name) > MAX_STRING_LENGTH || len(str) > MAX_STRING_LENGTH {
        return .StringTooLong
    }
    buf_write_byte(w, u8(NBTTag.String))
    buf_write_u16(w, u16(len(name)))
    buf_write_bytes(w, transmute([]u8)name)
    
    buf_write_u16(w, u16(len(str)))
    buf_write_bytes(w, transmute([]u8)str)
    return .None
}

@(require_results)
nbt_write_named_bool :: proc(w: ^NBTWriter, name: string, b: bool) -> WriteError {
    if len(name) > MAX_STRING_LENGTH {
        return .StringTooLong
    }
    buf_write_byte(w, u8(NBTTag.Byte))
    buf_write_u16(w, u16(len(name)))
    buf_write_bytes(w, transmute([]u8)name)
    
    buf_write_byte(w, u8(b))
    return .None
}