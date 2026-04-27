package crux

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
    Black    = 0x0,
    DarkAqua = 0x00aaaa,
}

@(private="file")
text_color_to_string :: proc(color: TextColor) -> string {
    switch color {
    case .Black: return "black"
    case .DarkAqua: return "dark_aqua"
    case: unimplemented()
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
            color := text_color_to_string(comp.style.color)
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