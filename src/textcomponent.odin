package crux

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
text_color_to_string :: proc(color: TextColor, hex_buf: ^[7]u8) -> string {
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

text_component :: proc(text: string, color: TextColor, features := TextFeatures{}) -> TextComponent {
    return StyledComponent { text = text, style = { color = color, features = features } }
}

serialize_text_component :: proc(buf: ^NetworkBuffer, comp: TextComponent) -> WriteError {
    writer := NBTWriter { buf = buf }
    
    switch comp in comp {
    case string:
        nbt_write_string(&writer, comp) or_return
    case StyledComponent:
        nbt_write_compound_start(&writer)
        defer nbt_write_compound_end(&writer)
        
        nbt_write_named_string(&writer, "text", comp.text) or_return
        if comp.style.color != {} {
            hex_buf: [7]u8
            color := text_color_to_string(comp.style.color, &hex_buf)
            nbt_write_named_string(&writer, "color", color) or_return
        }
        if .Bold in comp.style.features {
            nbt_write_named_bool(&writer, "bold", true) or_return
        }
        if .Italic in comp.style.features {
            nbt_write_named_bool(&writer, "italic", true) or_return
        }
        if .Underlined in comp.style.features {
            nbt_write_named_bool(&writer, "underlined", true) or_return
        }
        if .StrikeThrough in comp.style.features {
            nbt_write_named_bool(&writer, "strikethrough", true) or_return
        }
        if .Obfuscated in comp.style.features {
            nbt_write_named_bool(&writer, "obfuscated", true) or_return
        }
        
        // buf_write_byte(&writer, u8(NBTTag.List))
        // buf_write_u16(&writer, len("color"))
        // buf_write_bytes(&writer, transmute([]u8)string("color"))
        // buf_write_byte(&writer, u8(NBTTag.End))
    case TranslatableComponent:
        unimplemented()
    }
    return .None
}