package items

ItemStack :: struct {
    count: i32,
    type: ^ItemDescriptor,
    // Patches on top of default item descriptor, a `nil` component means that this component should be removed.
    patches: []Pair(DataComponentType, Maybe(DataComponent)),
}

create :: #force_inline proc(count: i32, type: ^ItemDescriptor, loc := #caller_location) -> ItemStack {
    assert(count <= type.max_stack_size, "cannot create item with count > max stack size", loc=loc)
    return ItemStack { count=count, type=type }
}

Pair :: struct($T, $U: typeid) {
    left: T,
    right: U,
}

ItemDescriptor :: struct #all_or_none {
    protocol_id: i16,
    max_stack_size: i32,
}

// Returns true when at least one item can be added to `into`, considering the item type
// and attributes such as max stack size, custom data, etc.
can_merge_into_partial :: proc(item: ItemStack, into: ItemStack) -> bool {
    if into.type == &AIR {
        // can always put an item into an empty slot
        return true
    }
    if item.type != into.type {
        return false
    }

    max_stack_size := into.type.max_stack_size
    if into.count + 1 > max_stack_size {
        return false
    }
    // TODO: compare actual patches against eachother
    if item.patches != nil || into.patches != nil {
        return false
    }
    return true
}

// Tries to add `amount` to the itemstack specified by `item`, returns the number of items
// actually added, considering the max stack size.
try_grow_stack :: proc(item: ^ItemStack, amount: i32) -> (grown_by: i32) {
    to_add := clamp(item.type.max_stack_size - item.count, 0, amount)
    item.count += to_add
    return to_add
}

DataComponent :: union {
    // TODO: define all other data component types
    MaxStackSizeDataComponent,
}
MaxStackSizeDataComponent :: distinct i32

// minecraft:data_component_type registry types
DataComponentType :: enum i32 {
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