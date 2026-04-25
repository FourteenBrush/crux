package crux

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

NBTCompound :: struct {
    
}

NBTWriter :: struct {
    #subtype buf: NetworkBuffer,
}

nbt_write_string :: proc(buf: ^NetworkBuffer, str: string) -> WriteError {
    buf_write_byte(buf, u8(NBTTag.String))
    if len(str) > int(max(u16)) {
        return .StringTooLong
    } 
    buf_write_u16(buf, u16(len(str)))
    buf_write_bytes(buf, transmute([]u8)str)
    return .None
}