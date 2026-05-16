package crux

import "core:fmt"
import "core:mem"

// Correctness considerations:
// - we must disallow writing named entries when not in a context where names are required
// - every write must answer the questions:
//      - am i inside a compound -> require a named entry
//      - am i inside a list -> (forbid name, do not use tag, enforce consistent element type)
//      - am i inside root compound -> forbid name (since mc 1.20.2)
// 
// - we must ensure that network nbt supports unnamed root compound tags, but not nbt in world saves, etc..
// - support modified utf-8 tag names
// - support automatic detection of whether a tag is required (not required for list elements)
NBTWriter :: struct {
    #subtype buf: ^NetworkBuffer,
    exclude_root_compound_name: bool,
    // Each level of nesting (compound/list) pushes a new frame on the stack.
    // An empty stack allows for arbitrary unnamed nbt writes not nested in a compound or list.
    frame_stack: [dynamic]ContainerFrame,
}

@(require_results)
create_nbt_writer :: proc(backing: ^NetworkBuffer, allocator: mem.Allocator, network_nbt: bool) -> (w: NBTWriter) {
    w.buf = backing
    w.exclude_root_compound_name = network_nbt && PROTOCOL_VERSION >= .V1_20_2
    w.frame_stack.allocator = allocator
    return w
}

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

@(private="file")
ContainerFrame :: bit_field u32 {
    kind: ContainerKind | 1,
    // Only used when type=.List, to ensure only identical list element types are written.
    list_elem_type: NBTTag | 4,
    // Only used when type=.List, represents the remaining number of entries that still has to be written.
    // Enforces an effective maximum of (1<<27)-1 (134,217,727) list entries, which seems fairly sufficient.
    list_nr_remaining: u32 | (32 - 5),
}
#assert(1 << 1 >= len(ContainerKind))
#assert(1 << 4 >= len(NBTTag))

// type safe marker to ensure list entry cursors are only advanced for unnamed writes
@(private="file")
UnnamedContainerFrame :: distinct ContainerFrame

@(private="file")
ContainerKind :: enum u8 {
    // To indicate a root compound tag, the index of this container in the stack must be 0.
    Compound,
    List,
}

@(private="file")
_MAX_NESTING_DEPTH :: 512

@(private="file")
_MAX_STRING_LENGTH :: int(max(u16))

@(require_results)
nbt_write_named_compound_start :: proc(w: ^NBTWriter, name: string) -> WriteError {
    _require_named_ctx(w)
    if len(name) > _MAX_STRING_LENGTH {
        return .StringTooLong
    }
    _push_frame(w, ContainerFrame { kind = .Compound })
    buf_write_byte(w, u8(NBTTag.Compound))
    if !w.exclude_root_compound_name {
        _write_field_name(w, name)
    }
    return .None
}

nbt_write_compound_start :: proc(w: ^NBTWriter) {
    _, requires_tag := _require_unnamed_ctx(w, .Compound)
    _push_frame(w, ContainerFrame { kind = .Compound, list_elem_type = {} })
    if requires_tag {
        buf_write_byte(w, u8(NBTTag.Compound))
    }
}

nbt_write_compound_end :: proc(w: ^NBTWriter) {
    // modifying stack is fine as we will panic for invariants
    frame, has_frame := pop_safe(&w.frame_stack)
    assert(
        has_frame && frame.kind == .Compound,
        "Incorrect nbt writer usage: attempted to end compound while not inside compound",
    )
    buf_write_byte(w, u8(NBTTag.End))
    #no_bounds_check possible_list_frame := len(w.frame_stack) == 0 ? nil : &w.frame_stack[len(w.frame_stack) - 1]
    _advance_list_entries(w, cast(^UnnamedContainerFrame) possible_list_frame)
}

@(require_results)
nbt_write_named_list_start :: proc(w: ^NBTWriter, name: string, elem_type: NBTTag, count: int) -> WriteError {
    _require_named_ctx(w)
    if len(name) > _MAX_STRING_LENGTH {
        return .StringTooLong
    }
    // Dont bother pushing bookkeeping frame when there are no elements which' write calls would advance the
    // list cursor and eventually pop the frame.
    if count > 0 {
        _push_frame(w, ContainerFrame { kind = .List, list_elem_type = elem_type, list_nr_remaining = u32(count) })
    }
    
    buf_write_byte(w, u8(NBTTag.List))
    _write_field_name(w, name)
    buf_write_byte(w, u8(elem_type))
    buf_write_u32(w, u32(count))
    return .None
}

nbt_write_list_start :: proc(w: ^NBTWriter, elem_type: NBTTag, count: int) {
    _, requires_tag := _require_unnamed_ctx(w, .List)
    // Dont bother pushing bookkeeping frame when there are no elements which' write calls would advance the
    // list cursor and eventually pop the frame.
    if count > 0 {
        _push_frame(w, ContainerFrame { kind = .List, list_elem_type = elem_type, list_nr_remaining = u32(count) })
    }
    
    if requires_tag {
        buf_write_byte(w, u8(NBTTag.List))
    }
    buf_write_byte(w, u8(elem_type))
    buf_write_u32(w, u32(count))
}

@(require_results)
nbt_write_named_string :: proc(w: ^NBTWriter, name: string, str: $S/string) -> WriteError {
    _require_named_ctx(w)
    if len(name) > _MAX_STRING_LENGTH || len(str) > _MAX_STRING_LENGTH {
        return .StringTooLong
    }
    buf_write_byte(w, u8(NBTTag.String))
    _write_field_name(w, name)
    
    buf_write_u16(w, u16(len(str)))
    buf_write_bytes(w, transmute([]u8)str)
    return .None
}

@(require_results)
nbt_write_string :: proc(w: ^NBTWriter, str: $S/string) -> WriteError {
    frame, requires_tag := _require_unnamed_ctx(w, .String)
    if len(str) > _MAX_STRING_LENGTH {
        return .StringTooLong
    } 
    if requires_tag {
        buf_write_byte(w, u8(NBTTag.String))
    }
    buf_write_u16(w, u16(len(str)))
    buf_write_bytes(w, transmute([]u8)str)
    _advance_list_entries(w, frame)
    return .None
}

@(require_results)
nbt_write_named_double :: proc(w: ^NBTWriter, name: string, d: f64) -> WriteError {
    _require_named_ctx(w)
    if len(name) > _MAX_STRING_LENGTH {
        return .StringTooLong
    }
    buf_write_byte(w, u8(NBTTag.Double))
    _write_field_name(w, name)
    buf_write_f64(w, d)
    return .None
}

@(require_results)
nbt_write_named_float :: proc(w: ^NBTWriter, name: string, f: f32) -> WriteError {
    _require_named_ctx(w)
    if len(name) > _MAX_STRING_LENGTH {
        return .StringTooLong
    }
    buf_write_byte(w, u8(NBTTag.Float))
    _write_field_name(w, name)
    buf_write_f32(w, f)
    return .None
}

@(require_results)
nbt_write_named_int :: proc(w: ^NBTWriter, name: string, i: i32) -> WriteError {
    _require_named_ctx(w)
    if len(name) > _MAX_STRING_LENGTH {
        return .StringTooLong
    }
    buf_write_byte(w, u8(NBTTag.Int))
    _write_field_name(w, name)
    buf_write_i32(w, i)
    return .None
}

@(require_results)
nbt_write_named_bool :: proc(w: ^NBTWriter, name: string, b: bool) -> WriteError {
    _require_named_ctx(w)
    if len(name) > _MAX_STRING_LENGTH {
        return .StringTooLong
    }
    buf_write_byte(w, u8(NBTTag.Byte))
    _write_field_name(w, name)
    buf_write_byte(w, u8(b))
    return .None
}

nbt_write_bool :: proc(w: ^NBTWriter, b: bool) {
    frame, requires_tag := _require_unnamed_ctx(w, .Byte)
    if requires_tag {
        buf_write_byte(w, u8(NBTTag.Byte))
    }
    buf_write_byte(w, u8(b))
    _advance_list_entries(w, frame)
}

@(private="file")
_write_field_name :: #force_inline proc(w: ^NBTWriter, name: string) {
    buf_write_u16(w, u16(len(name)))
    buf_write_bytes(w, transmute([]u8)name)
}

@(private="file")
_require_named_ctx :: proc(w: ^NBTWriter, loc := #caller_location) {
    // root compound would be sitting at index 0, which does not require a name
    // TODO: should top level lists be allowed?
    if len(w.frame_stack) <= 1 do return
    #no_bounds_check frame := w.frame_stack[len(w.frame_stack) - 1]
    assert(
        frame.kind == .Compound,
        "Incorrect nbt_write_named_* usage, attempted to write named entry in a context forbidding named entries",
        loc=loc,
    )
}

@(private="file", require_results)
_require_unnamed_ctx :: proc(
    w: ^NBTWriter,
    self_list_elem_type: NBTTag,
    loc := #caller_location,
) -> (
    frame: ^UnnamedContainerFrame,
    requires_tag: bool,
) {
    if len(w.frame_stack) == 0 {
        return nil, true
    }
    #no_bounds_check frame = cast(^UnnamedContainerFrame) &w.frame_stack[len(w.frame_stack) - 1]
    assert(
        frame.kind == .List,
        "Incorrect nbt_write_* usage, attempted to write unnamed entry in a context requiring named entries",
        loc=loc,
    )
    fmt.assertf(
        frame.list_elem_type == self_list_elem_type,
        "Incorrect nbt_write_* usage, list declares element type to be %s, but was trying to write %s",
        frame.list_elem_type, self_list_elem_type,
        loc=loc,
    )
    return frame, false
}

@(private="file")
_push_frame :: #force_inline proc(w: ^NBTWriter, frame: ContainerFrame) {
    assert(len(w.frame_stack) < _MAX_NESTING_DEPTH, "NBT exceeds max nesting")
    append(&w.frame_stack, frame)
}

@(private="file")
_advance_list_entries :: proc(w: ^NBTWriter, frame: ^UnnamedContainerFrame) {
    if frame == nil || frame.kind != .List do return
    frame.list_nr_remaining -= 1
    if frame.list_nr_remaining == 0 {
        // pop list frame automatically if this is the last entry being written, to avoid
        // writing clumsy explicit write_list_end() calls
        assert(pop(&w.frame_stack) == ContainerFrame(frame^), "frame pushed between input param and popped")
    }
}
