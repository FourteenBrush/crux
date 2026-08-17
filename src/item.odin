package crux

ItemStack :: struct {
    count: i32,
    item: ^ItemDescriptor,
    // Patches on top of default item descriptor, a `nil` component means that this component should be removed.
    patches: []Pair(DataComponentType, Maybe(DataComponent)),
}

Pair :: struct($T, $U: typeid) {
    left: T,
    right: U,
}

ItemDescriptor :: struct #all_or_none {
    protocol_id: i16,
    max_stack_size: i32,
}

@(rodata)
ITEM_AIR := ItemDescriptor {
    protocol_id = 0,
    max_stack_size = 64,
}
@(rodata)
ITEM_DIRT := ItemDescriptor {
    protocol_id = 28,
    max_stack_size = 64,
}

@(private)
AddItemIterator :: struct {
    inv: ^Inventory,
    to_add: ItemStack,
    // Slot index into inventory grid, _not_ slot number.
    last_slot_idx_tried: i16,
}

@(private, require_results)
_create_add_item_iterator :: proc(target: ^Inventory, to_add: ItemStack) -> (it: AddItemIterator) {
    it.inv = target
    it.to_add = to_add
    return it
}

@(private)
_add_item_iterator :: proc(it: ^AddItemIterator) -> (slot_nr: i16, item: ItemStack, ok: bool) {
    if it.to_add.count == 0 do return
    
    for i in it.last_slot_idx_tried..<len(INVENTORY_INSERT_ORDER) {
        defer it.last_slot_idx_tried += 1

        #no_bounds_check slot_nr := INVENTORY_INSERT_ORDER[i]
        item := &it.inv.items[slot_nr]

        if item.item != it.to_add.item && item.item != &ITEM_AIR {
            continue
        }

        if item.item == &ITEM_AIR {
            // update material so we are not increasing the count of an air itemstack
            item.item = it.to_add.item
        }

        max_stack_size := item.item.max_stack_size
        if item.count < max_stack_size {
            to_add := min(max_stack_size - item.count, it.to_add.count)
            item.count += to_add
            it.to_add.count -= to_add
            return slot_nr, item^, true
        }
    }
    return -1, item, false
}

// minecraft:data_component_type registry types
DataComponentType :: enum VarInt {
    CustomData,
    MaxStackSize,
    MaxDamage,
    Damage,
    Unbreakable,
    CustomName,
    ItemName,
    ItemModel,
    Lore,
    Rarity,
    Enchantments,
    CanPlaceOn,
    CanBreak,
    AttributeModifiers,
    CustomModelData,
    TooltipDisplay,
    RepairCost,
    CreativeSlotLock,
    EnchantmentGlintOverride,
    IntangibleProjectile,
    Food,
    Consumable,
    UseRemainder,
    UseCooldown,
    UseEffects,
    MinimumAttackCharge,
    DamageType,
    DamageResistant,
    AttackRange,
    Tool,
    Weapon,
    Enchantable,
    Equippable,
    Repairable,
    Glider,
    TooltipStyle,
    DeathProtection,
    BlocksAttacks,
    StoredEnchantments,
    DyedColor,
    MapColor,
    MapId,
    MapDecorations,
    MapPostProcessing,
    ChargedProjectiles,
    BundleContents,
    PotionContents,
    PotionDurationScale,
    SuspiciousStewEffects,
    WritableBookContent,
    WrittenBookContent,
    Trim,
    DebugStickState,
    EntityData,
    BucketEntityData,
    BlockEntityData,
    Instrument,
    PiercingWeapon,
    KineticWeapon,
    SwingAnimation,
    AdditionalTradeCost,
    Dye,
    ProvidesTrimMaterial,
    OminousBottleAmplifier,
    JukeboxPlayable,
    ProvidesBannerPatterns,
    Recipes,
    LodestoneTracker,
    FireworkExplosion,
    Fireworks,
    Profile,
    NoteBlockSound,
    BannerPatterns,
    BaseColor,
    PotDecorations,
    Container,
    BlockState,
    Bees,
    Lock,
    ContainerLoot,
    BreakSound,
    SulfurCubeContent,
    VillagerVariant,
    WolfVariant,
    WolfSoundVariant,
    WolfCollar,
    FoxVariant,
    SalmonSize,
    ParrotVariant,
    TropicalFishPattern,
    TropicalFishBaseColor,
    TropicalFishPatternColor,
    MooshroomVariant,
    RabbitVariant,
    PigVariant,
    PigSoundVariant,
    CowVariant,
    CowSoundVariant,
    ChickenVariant,
    ChickenSoundVariant,
    FrogVariant,
    HorseVariant,
    PaintingVariant,
    LlamaVariant,
    AxolotlVariant,
    ZombieNautilusVariant,
    CatVariant,
    CatSoundVariant,
    CatCollar,
    SheepColor,
    ShulkerColor,
}