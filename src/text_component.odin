package crux

import "core:mem"
import "core:strconv"
import "core:encoding/json"

TextComponent :: union {
    // Plain text component without any styling applied.
    string,
    StyledComponent,
    TranslatableComponent,
}

StyledComponent :: struct {
    using _: TextComponentBase,
    text: string,
}

TranslatableComponent :: struct {
    using _: TextComponentBase,
    // A translation identifier.
    translate: string,
    // Translated text to be used when no corresponding translation can be found.
    fallback: Maybe(string),
    // Text components to be inserted into slots in the translation text.
    with: [dynamic]TextComponent,
}

TextComponentBase :: struct {
    style: TextStyle,
    children: [dynamic]TextComponent,
}

TextStyle :: struct {
    color: TextColor,
    // TODO: font, shadow_color and interactivity
    features: TextFeatures,
}

TextFeatures :: bit_set[TextFeature]
TextFeature :: enum {
    Bold,
    Italic,
    Underlined,
    StrikeThrough,
    Obfuscated,
}

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
_text_color_to_string :: proc(color: TextColor, arena: mem.Allocator) -> string {
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
        hex_buf := make([]u8, 7, arena)
        hex_buf[0] = '#'
        strconv.write_int(hex_buf[1:], i64(color), 16)
        return string(hex_buf[:])
    }
}

text_component :: proc{
    text_component_single,
    text_component_children,
}

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

serialize_text_component :: proc{
    serialize_text_component_nbt,
    serialize_text_component_json,
}

@(require_results)
serialize_text_component_nbt :: proc(buf: ^NetworkBuffer, comp: TextComponent) -> WriteError {
    writer := create_nbt_writer(buf, context.temp_allocator, network_nbt=true)
    
    switch comp in comp {
    case string:
        nbt_write_string(&writer, comp) or_return
    case StyledComponent:
        nbt_write_compound_start(&writer)
        defer nbt_write_compound_end(&writer)
        
        nbt_write_named_string(&writer, "text", comp.text) or_return
        _serialize_text_style(&writer, comp.style) or_return
        _serialize_children(&writer, "extra", comp.children[:]) or_return
    case TranslatableComponent:
        nbt_write_compound_start(&writer)
        defer nbt_write_compound_end(&writer)

        nbt_write_named_string(&writer, "translate", comp.translate) or_return
        if fallback, ok := comp.fallback.?; ok {
            nbt_write_named_string(&writer, "fallback", fallback) or_return
        }
        
        _serialize_text_style(&writer, comp.style) or_return
        _serialize_children(&writer, "extra", comp.children[:]) or_return
        _serialize_children(&writer, "with", comp.with[:]) or_return
    }
    return .None
}

@(private="file", require_results)
_serialize_text_style :: proc(writer: ^NBTWriter, style: TextStyle) -> WriteError {
    if style.color != {} {
        // avoid touching heap when not necessary
        hex_buf: [7]u8
        color := _text_color_to_string(style.color, mem.arena_allocator(&mem.Arena { data = hex_buf[:] }))
        nbt_write_named_string(writer, "color", color) or_return
    }
    if .Bold in style.features {
        nbt_write_named_bool(writer, "bold", true) or_return
    }
    if .Italic in style.features {
        nbt_write_named_bool(writer, "italic", true) or_return
    }
    if .Underlined in style.features {
        nbt_write_named_bool(writer, "underlined", true) or_return
    }
    if .StrikeThrough in style.features {
        nbt_write_named_bool(writer, "strikethrough", true) or_return
    }
    if .Obfuscated in style.features {
        nbt_write_named_bool(writer, "obfuscated", true) or_return
    }
    return .None
}

@(private="file", require_results)
_serialize_children :: proc(writer: ^NBTWriter, key: string, children: []TextComponent) -> WriteError {
    if len(children) > 0 {
        nbt_write_named_list_start(writer, key, .Compound, len(children)) or_return
        for child in children {
            serialize_text_component(writer, child) or_return
        }
    }
    return .None
}

serialize_text_component_json :: proc(comp: TextComponent, allocator: mem.Allocator) -> []u8 {
    dto := _text_component_to_json_dto(comp, context.temp_allocator)
    data, err := json.marshal(dto, allocator=allocator)
    assert(err == nil)
    return data
}

@(private="file")
_text_component_to_json_dto :: proc(comp: TextComponent, temp_alloc: mem.Allocator) -> TextComponentJson {
    comp_json: TextComponentJson
    
    switch comp in comp {
    case string:
        comp_json = StyledComponentJson { text=comp }
    case StyledComponent:
        comp_json = StyledComponentJson {
            text = comp.text,
            
            color = _text_color_to_string(comp.style.color, temp_alloc),
            bold = .Bold in comp.style.features,
            italic = .Italic in comp.style.features,
            underlined = .Underlined in comp.style.features,
            strikethrough = .StrikeThrough in comp.style.features,
            obfuscated = .Obfuscated in comp.style.features,
        }
    case TranslatableComponent:
        with: Maybe([]TextComponentJson) = nil
        if len(comp.with) > 0 {
            with = make([]TextComponentJson, len(comp.with))
            with_ := with.?
            for comp, i in comp.with {
                with_[i] = _text_component_to_json_dto(comp, temp_alloc)
            }
        }
        
        comp_json = TranslatableTextComponentJson {
            translate = comp.translate,
            fallback = comp.fallback,
            
            
            color = _text_color_to_string(comp.style.color, temp_alloc),
            bold = .Bold in comp.style.features,
            italic = .Italic in comp.style.features,
            underlined = .Underlined in comp.style.features,
            strikethrough = .StrikeThrough in comp.style.features,
            obfuscated = .Obfuscated in comp.style.features,
        }
    }
    
    return comp_json
}

@(private="file")
TextComponentJson :: union {
    StyledComponentJson,
    TranslatableTextComponentJson,
}

@(private="file")
TextComponentJsonBase :: struct {
    color: string,
    // from TextFeatures
    bold: bool,
    italic: bool,
    underlined: bool,
    strikethrough: bool,
    obfuscated: bool,
}

@(private="file")
StyledComponentJson :: struct {
    using _: TextComponentJsonBase,
    text: string,
}

@(private="file")
TranslatableTextComponentJson :: struct {
    using _: TextComponentJsonBase,
    translate: string,
    // 'omitempty' does not seem to work on strings
    fallback: Maybe(string),
    with: Maybe([]TextComponentJson),
}