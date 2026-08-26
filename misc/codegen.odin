#+vet explicit-allocators
package codegen

import "core:path/filepath"
import "core:os"
import "core:fmt"
import "core:mem"
import "core:flags"
import "core:strings"
import "core:encoding/json"
import vmem "core:mem/virtual"

ItemsJsonModel :: distinct map[string]ItemSpec

ItemSpec :: struct {
    components: json.Object,
}

RegistriesJsonModel :: distinct map[string]RegistrySpec

RegistrySpec :: struct {
    entries: map[string]struct { protocol_id: int },
}

PKG_NAME :: "items"

main :: proc() {
    arena: vmem.Arena
    arena_init_err := vmem.arena_init_growing(&arena, 1 * mem.Megabyte)
    if arena_init_err != .None {
        fmt.eprintln("Failed to initialize arena:", arena_init_err)
        os.exit(1)
    }
    defer vmem.arena_destroy(&arena)
    context.allocator = vmem.arena_allocator(&arena)

    cli_args: struct {
        output_file: string `args:"required" usage:"Output file path for generated code"`,
        delete_conflicting_outputs: bool `usage:"Delete existing generated outputs that would get overwritten"`,
    }
    flags.parse_or_exit(&cli_args, os.args, .Unix, context.allocator)

    open_flags := os.File_Flags{.Write, .Create}
    if cli_args.delete_conflicting_outputs {
        open_flags += {.Trunc}
    } else {
        open_flags += {.Excl}
    }
    output_file, output_err := os.open(cli_args.output_file, open_flags)
    if output_err == .Exist && !cli_args.delete_conflicting_outputs {
        fmt.eprintln("Could not output generated code, file exists, consider passing --delete-conflicting-outputs to overwrite this existing file")
        os.exit(1)
    }
    if output_err != nil {
        fmt.eprintln("Failed to open output file, ensure parent directory exists:", os.error_string(output_err))
        os.exit(1)
    }
    defer os.close(output_file)

    registries, items := load_models(context.allocator) or_else os.exit(1)

    sb := strings.builder_make(0, 64 * mem.Kilobyte, context.allocator)
    defer strings.builder_destroy(&sb)

    if !generate_code(items, registries, &sb) {
        os.exit(1)
    }

    _,  write_err := os.write_string(output_file, strings.to_string(sb))
    if write_err != nil {
        fmt.eprintln("Failed to write to output file:", os.error_string(write_err))
        os.exit(1)
    }

    cwd := os.get_working_directory(context.allocator) or_else panic("cannot get cwd?")
    output_path := filepath.rel(cwd, os.name(output_file), context.allocator) or_else os.name(output_file)
    fmt.println("Generated code written to", output_path)
}

@(require_results)
generate_code :: proc(items: ItemsJsonModel, registries: RegistriesJsonModel, sb: ^strings.Builder) -> bool {
    item_registry, has_item_registry := registries["minecraft:item"]
    if !has_item_registry {
        fmt.println("Unable to find 'minecraft:item' registry inside json file")
        return false
    }

    fmt.sbprintf(sb,
`/* 
    GENERATED CODE, DO NOT EDIT MANUALLY
 */
package %s
`, PKG_NAME)

    for item_id, spec in item_registry.entries {
        prefix :: "minecraft:"
        if !strings.starts_with(item_id, prefix) {
            fmt.eprintln("Unexpected item identifier with missing 'minecraft:' prefix:", item_id)
            return false
        }

        item_spec, has_item_spec := items[item_id]
        if !has_item_spec {
            fmt.eprintfln("Unable to find item %s in items json file", item_id)
            return false
        }
        max_stack_size_: Maybe(i64)
        for comp_name, comp_value in item_spec.components do if comp_name == "minecraft:max_stack_size" {
            is_int: bool
            max_stack_size_, is_int = comp_value.(json.Integer)
            if !is_int {
                fmt.eprintln("data attribute for minecraft:max_stack_size was not an int")
                return false
            }
            break
        }
        
        if max_stack_size_ == nil {
            fmt.eprintln("Missing minecraft:max_stack_size attribute in items json spec")
            return false
        }
        max_stack_size := max_stack_size_.?

        item_id := item_id[len(prefix):]
        odin_item_name := strings.to_upper_snake_case(item_id, context.allocator) or_else panic("ALLOC ERR")

        
        fmt.sbprintf(sb,
`
@(rodata)
%s := ItemDescriptor {{
    protocol_id = %d,
    max_stack_size = %d,
}}
`, odin_item_name, spec.protocol_id, max_stack_size)
    }

    return true
}

load_models :: proc(allocator: mem.Allocator) -> (registries: RegistriesJsonModel, items: ItemsJsonModel, ok: bool) {
    registries = decode_json(#load("../datagen/registries.json"), RegistriesJsonModel, context.allocator) or_return
    items = decode_json(#load("../datagen/items.json"), ItemsJsonModel, context.allocator) or_return
    return registries, items, true
}

decode_json :: proc(bytes: []u8, $Model: typeid, allocator: mem.Allocator) -> (model: Model, ok: bool) {
    decode_err := json.unmarshal(bytes, &model, allocator=allocator)
    if decode_err != nil {
        fmt.eprintln("Failed to unmarshal json file:", decode_err)
        return model, false
    }
    return model, true
}