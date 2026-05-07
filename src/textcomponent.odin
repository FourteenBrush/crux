package crux

import "core:mem"
import "core:strconv"

TextComponent :: union {
    // Plain text component without any styling applied.
    string,
    StyledComponent,
    TranslatableComponent,
}

StyledComponent :: struct {
    text: string,
    style: TextStyle,
    children: [dynamic]TextComponent,
}

TranslatableComponent :: struct {
    // A translation identifier.
    translate: string,
    // Translated text to be used when no corresponding translation can be found.
    fallback: string,
}

TextStyle :: struct {
    color: TextColor,
    features: TextFeatures,
}

TextFeatures :: bit_set[enum {
    Bold,
    Italic,
    Underlined,
    StrikeThrough,
    Obfuscated,
}]

TextColor :: enum u32 {
    Black       = 0x0,
    DarkBlue    = 0x0000aa,
    DarkGreen   = 0x00aa00,
    DarkAqua    = 0x00aaaa,
    DarkRed     = 0xaa0000,
    DarkPurple  = 0xaa00aa,
    Gold        = 0xffaa00,
    Gray        = 0xaaaaaa,
    DarkGray    = 0x555555,
    Blue        = 0x5555ff,
    Green       = 0x55ff55,
    Aqua        = 0x55ffff,
    Red         = 0xff5555,
    LightPurple = 0xff55ff,
    Yellow      = 0xffff55,
    White       = 0xffffff,
}

@(private="file")
_text_color_to_string :: proc(color: TextColor, hex_buf: ^[7]u8) -> string {
    switch color {
    case .Black: return "black"
    case .DarkBlue: return "dark_blue"
    case .DarkGreen: return "dark_green"
    case .DarkAqua: return "dark_aqua"
    case .DarkRed: return "dark_red"
    case .DarkPurple: return "dark_purple"
    case .Gold: return "gold"
    case .Gray: return "gray"
    case .DarkGray: return "dark_gray"
    case .Blue: return "blue"
    case .Green: return "green"
    case .Aqua: return "aqua"
    case .Red: return "red"
    case .LightPurple: return "light_purple"
    case .Yellow: return "yellow"
    case .White: return "white"
    case:
        assert(int(color) <= 0xffffff, "invalid casted color bigger than #ffffff")
        hex_buf[0] = '#'
        strconv.write_int(hex_buf[1:], i64(color), 16)
        return string(hex_buf[:])
    }
}

text_component :: proc{text_component_single, text_component_children}

text_component_single :: proc(text: string, color: TextColor, features := TextFeatures{}) -> TextComponent {
    return StyledComponent { text = text, style = { color = color, features = features } }
}

text_component_children :: proc(
    text: string,
    color: TextColor,
    features := TextFeatures{},
    children: []TextComponent,
    children_allocator: mem.Allocator,
) -> TextComponent {
    component := StyledComponent {
        text = text,
        style = TextStyle { color = color, features = features },
    }
    context.allocator = children_allocator
    append(&component.children, ..children)
    return component
}

@(require_results)
serialize_text_component :: proc(buf: ^NetworkBuffer, comp: TextComponent) -> WriteError {
    writer := NBTWriter { buf = buf }
    return _serialize_text_component(&writer, comp, .Full)
}

@(private="file")
EmitMode :: enum {
    // Omit full tag and payload
    Full,
    // Omit tag, used when writing list elements, which do not carry a tag as it's encoded
    // once in the list "header".
    OmitTag,
}

@(private="file", require_results)
_serialize_text_component :: proc(writer: ^NBTWriter, comp: TextComponent, mode: EmitMode) -> WriteError {
    switch comp in comp {
    case string:
        nbt_write_string(writer, comp) or_return
    case StyledComponent:
        if mode == .Full {
            nbt_write_compound_start(writer)
        }
        defer nbt_write_compound_end(writer)
        
        nbt_write_named_string(writer, "text", comp.text) or_return
        if comp.style.color != {} {
            hex_buf: [7]u8
            color := _text_color_to_string(comp.style.color, &hex_buf)
            nbt_write_named_string(writer, "color", color) or_return
        }
        if .Bold in comp.style.features {
            nbt_write_named_bool(writer, "bold", true) or_return
        }
        if .Italic in comp.style.features {
            nbt_write_named_bool(writer, "italic", true) or_return
        }
        if .Underlined in comp.style.features {
            nbt_write_named_bool(writer, "underlined", true) or_return
        }
        if .StrikeThrough in comp.style.features {
            nbt_write_named_bool(writer, "strikethrough", true) or_return
        }
        if .Obfuscated in comp.style.features {
            nbt_write_named_bool(writer, "obfuscated", true) or_return
        }
        
        if len(comp.children) > 0 {
            nbt_write_named_list_start(writer, "extra", .Compound, len(comp.children)) or_return
            for child in comp.children {
                _serialize_text_component(writer, child, .OmitTag) or_return
            }
        }
    case TranslatableComponent:
        unimplemented()
    }
    return .None
}