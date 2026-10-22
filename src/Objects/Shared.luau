--!strict
-- The parts of an object that are the same on both sides.
--
-- Property lookup and name resolution have always been here. The link machinery
-- joined them when the client learned to own scenes of its own: a local object
-- has to drive its instance exactly as a replicated one does, and a prefab
-- preview whose Color never reaches the part is not a preview. None of it is
-- side specific -- it needs the property registry and nothing else -- so the
-- side is resolved here the way the compressor resolves it, rather than the
-- code being written twice and drifting.

const RunService = game:GetService("RunService")

-- Typed as the server half. The two halves share every member this file uses,
-- but the default solver cannot call through a union of two module types even
-- when their signatures match.
const Properties: typeof(require("../Properties/Server")) = if RunService:IsClient()
    then require("../Properties/Client") :: any
    else require("../Properties/Server")

const PropertyTypes = require("../Properties/Types")
const Compressor = require("../Compressor")
const Logger = require("../Logger")
const Types = require("./Types")

const function NoDisconnect() end

-- Name -> id, built once when the object is. Get, Set and OnChange all take a
-- name as readily as an id, and resolving one used to scan every property on
-- the object -- over a hash keyed table, so two properties sharing a name
-- resolved to whichever one iteration happened to reach first. Built from the
-- registry's ordered property list instead: the lookup is constant, and the
-- name declared first wins every time.
const function BuildNameMap(
    Order: {PropertyTypes.PropertyIdentifier},
    Props: {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>}
): {[string]: PropertyTypes.PropertyIdentifier}
    const Map = {}
    for _, Identifier in Order do
        const Prop = Props[Identifier]
        if Prop and Map[Prop.Name] == nil then
            Map[Prop.Name] = Identifier
        end
    end

    return Map
end

const function GetProperty(
    self: Types.Object,
    Reference: Types.PropertyReference
): PropertyTypes.Property<any>?
    if type(Reference) == "number" then
        return self.Properties[Reference]
    end

    const Identifier = self.Names[Reference]
    return if Identifier then self.Properties[Identifier] else nil
end

-- The object level counterpart to Set and Get: the same reference, resolved the
-- same way. Watching a property used to mean reaching into Properties by id,
-- which forced the caller to hold the id even though every other method on the
-- object accepts a name.
const function OnChange(
    self: Types.Object,
    Reference: Types.PropertyReference,
    Callback: (Value: any) -> ()
): () -> ()
    const Prop = GetProperty(self, Reference)
    if not Prop then
        -- Not an error, to match Get answering nil and Set answering false for
        -- a reference the object does not carry. But a listener that silently
        -- never fires is far harder to spot than either of those, so it warns.
        Logger:Warn(`Cannot watch {Reference} on {self.Name}: the object has no such property.`)
        return NoDisconnect
    end

    return Prop:OnChange(Callback)
end

const function BuildProperties(
    Order: {PropertyTypes.PropertyIdentifier}
): {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>}
    const Map = {}
    for _, Identifier in Order do
        Map[Identifier] = Properties.new(Identifier)
    end

    return Map
end

--=============================================================================
-- Links
--=============================================================================

-- ReflectionService is plugin security, so a live game cannot call it. Reading
-- the property is enough to learn both whether it exists and what type it is.
--
-- A member that exists but currently holds nil reports as unknown rather than
-- as the string "nil", which is truthy and used to sail past the caller's guard
-- and then fail the type comparison with a misleading message.
const function GetInstancePropertyType(Inst: Instance, Name: string): string?
    const Ok, Value = pcall(function()
        return (Inst :: any)[Name]
    end)

    if not Ok or Value == nil then
        return nil
    end

    return typeof(Value)
end

-- Reading proves a member exists; only writing proves it can be set. Assigning
-- the value it already holds settles that without changing anything, so a link
-- to a read-only member like AbsoluteSize is refused at registration instead of
-- throwing inside Objects.new and then again from every change listener, where
-- the spawned thread swallows it.
const function IsWritable(Inst: Instance, Name: string): boolean
    const Ok, Current = pcall(function()
        return (Inst :: any)[Name]
    end)

    if not Ok then
        return false
    end

    return (pcall(function()
        (Inst :: any)[Name] = Current
    end))
end

-- Roblox attributes hold only these. EnumItem is not among them, and neither is
-- the table a CustomEnum option is, so SetAttribute throws on both rather than
-- failing quietly. Property links have always been type checked; this is the
-- equivalent for attribute links, which were not checked at all.
const ATTRIBUTE_TYPES: {[string]: true} = {
    string = true,
    boolean = true,
    number = true,
    UDim = true,
    UDim2 = true,
    BrickColor = true,
    Color3 = true,
    Vector2 = true,
    Vector3 = true,
    CFrame = true,
    NumberSequence = true,
    ColorSequence = true,
    NumberRange = true,
    Rect = true,
    Font = true,
}

-- Links are checked once, against the template, when the type is registered on
-- the server. A client receives them already checked, beside the template they
-- were checked against. Every clone has the same class and the same members, so the answer never
-- differs between them, and these checks used to run inside Objects.new, which
-- meant one malformed link warned once for every object ever created from that
-- registry.
const function ValidateLinks(
    Name: string,
    Target: Instance?,
    Links: {Types.InstanceLinkRegistry}?,
    PropertyIds: {PropertyTypes.PropertyIdentifier}
): {Types.InstanceLinkRegistry}?
    if not Links or #Links == 0 then
        return nil
    end

    if not Target then
        Logger:Warn(`Object {Name} declares links but has no Instance for them to drive. Links dropped.`)
        return nil
    end

    const Owned = {}
    for _, Id in PropertyIds do
        Owned[Id] = true
    end

    const Valid = {}
    const Seen = {}

    for _, Link in Links do
        const Registry = Properties:GetRegistry(Link.Property)
        if not Registry or not Owned[Link.Property] then
            Logger:Warn(`Object {Name} links property {Link.Property}, which it does not carry. Link dropped.`)
            continue
        end

        -- One link per property. The map holding them is keyed by property id,
        -- so a second link overwrote the first, leaving the first's change
        -- listener connected with nothing holding its disconnect -- still
        -- writing to its target for the whole life of the object.
        if Seen[Link.Property] then
            Logger:Warn(`Object {Name} links property {Registry.Name} more than once. The duplicate is dropped.`)
            continue
        end

        -- Said here rather than left to the type check below, which an Object
        -- would sail past: a reference is a local id, so Luau calls it a
        -- number and a link would happily drive an IntValue with it. What the
        -- instance would get is an id that means nothing outside the copy it
        -- came from, updated whenever the reference changes and pointing at a
        -- different object the moment the scene is loaded twice.
        if Registry.Type == "Object" then
            Logger:Warn(`Object {Name} links {Registry.Name}, which is an Object reference. A reference cannot drive an instance member. Link dropped.`)
            continue
        end

        -- No instance member or attribute holds a Luau table.
        if Registry.Type == "Table" then
            Logger:Warn(`Object {Name} links {Registry.Name}, which is a Table. A list cannot drive an instance member. Link dropped.`)
            continue
        end

        const Inst = if Link.Descendant
            then Target:FindFirstChild(Link.Descendant, true)
            else Target

        if not Inst then
            Logger:Warn(`Object {Name} links to a descendant named {Link.Descendant}, which {Target.Name} does not have. Link dropped.`)
            continue
        end

        const Expected = PropertyTypes.Map[Registry.Type]

        if Link.Type == "Property" then
            const Actual = GetInstancePropertyType(Inst, Link.Name)
            if not Actual then
                Logger:Warn(`Object {Name} links to {Inst.ClassName}.{Link.Name}, which is not readable or holds nil. Link dropped.`)
                continue
            end

            if Actual ~= Expected then
                Logger:Warn(`Object {Name} links {Registry.Name} ({Expected}) to {Inst.ClassName}.{Link.Name} ({Actual}). Link dropped.`)
                continue
            end

            if not IsWritable(Inst, Link.Name) then
                Logger:Warn(`Object {Name} links to {Inst.ClassName}.{Link.Name}, which is read only. Link dropped.`)
                continue
            end
        elseif Link.Type == "Attribute" then
            if not ATTRIBUTE_TYPES[Expected] then
                Logger:Warn(`Object {Name} links {Registry.Name} to an attribute, but a Roblox attribute cannot hold {Expected}. Link dropped.`)
                continue
            end
        else
            Logger:Warn(`Object {Name} has a link of type {Link.Type}, which is neither Property nor Attribute. Link dropped.`)
            continue
        end

        Seen[Link.Property] = true
        table.insert(Valid, Link)
    end

    return if #Valid > 0 then Valid else nil
end

-- Wiring only. ValidateLinks has already rejected anything that cannot work and
-- every clone shares the template's shape, so this no longer warns about link
-- shape -- it would repeat the same message once per object. The pcall stays
-- because the clone is not literally the instance that was validated.
const function BuildLinks(
    Target: Instance?,
    Links: {Types.InstanceLinkRegistry}?,
    Props: {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>}
): {[PropertyTypes.PropertyIdentifier]: Types.InstanceLink}?
    if not Links or not Target then
        return nil
    end

    const Map = {}
    local Count = 0

    for _, Registry in Links do
        const Link: Types.InstanceLink = table.clone(Registry) :: any
        const Prop = Props[Link.Property]
        if not Prop then
            continue
        end

        const Inst = if Link.Descendant
            then Target:FindFirstChild(Link.Descendant, true)
            else Target

        if not Inst then
            continue
        end

        const Apply = if Link.Type == "Attribute"
            then function(Value: any)
                Inst:SetAttribute(Link.Name, Value)
            end
            else function(Value: any)
                (Inst :: any)[Link.Name] = Value
            end

        if Prop.Value ~= nil and not pcall(Apply, Prop.Value) then
            Logger:Warn(`Failed to apply link {Link.Name} on {Inst.ClassName}. Link dropped.`)
            continue
        end

        Link.Disconnect = Prop:OnChange(Apply)
        Map[Link.Property] = Link
        Count += 1
    end

    return if Count > 0 then Map else nil
end

--=============================================================================
-- References
--=============================================================================

-- An Object property holds the target's local id -- the low half of its
-- persistent id -- and nothing else. That is what makes a reference survive a
-- save: it is written exactly as the pack's own ids are, and the scene stamps
-- its own id on at load, so every reference inside a pack moves by the same
-- amount and still names what it named.
--
-- A local id only means something inside one copy. Ask a scene loaded twice for
-- local id 4 and there are two answers, which is the whole point: two loaded
-- copies of one room each point at their own door. So resolution always goes
-- through the copy holding the object doing the referring, never through a
-- scene and never through the workspace.
--
-- Each side hands in its own Find, because Shared cannot require the module
-- that requires it: the server reads the copy's ByLocal, the client its index
-- of the same thing.

export type Find = (Instance_: Types.SceneInstanceId, Local: number) -> Types.Object?

-- No target. Zero rather than nil, because a property with no value reads as
-- its default and the format has to write something either way.
const NO_TARGET = 0

const function AllowedType(Constraints: any, Target: Types.Object): boolean
    if not Constraints or not Constraints.Types then
        return true
    end

    return table.find(Constraints.Types, Target.Registry) ~= nil
        or table.find(Constraints.Types, Target.Name) ~= nil
end

-- The live object an Object property points at, or nil. Nil covers three cases
-- that are deliberately not told apart: the property holds no target, the
-- target was destroyed, and the target has not been built yet -- a pack
-- restores its objects one at a time, so a button is read back before the door
-- it points at exists. The stored id is untouched in all three, so a target
-- that comes back under the local id it had -- a copy loaded again from the
-- same pack -- is pointed at again by everything that pointed at it.
const function ResolveReference(Copy: Types.SceneInstanceId, Value: any, Find: Find): Types.Object?
    if type(Value) ~= "number" or Value == NO_TARGET then
        return nil
    end

    const Target = Find(Copy, Value)
    if not Target or Target.Destroyed then
        return nil
    end

    return Target
end

-- What reading a property that holds references answers: the object an Object
-- property names, or the objects a Table of them names, in order. A list leaves
-- out every item that does not resolve rather than holding a hole for it --
-- the ids are still on the property, through GetProperty, for anyone who needs
-- to know which were missing.
const function ResolveValue(Copy: Types.SceneInstanceId, Prop: PropertyTypes.Property<any>, Value: any, Find: Find): any
    if Prop.Type ~= "Table" then
        return ResolveReference(Copy, Value, Find)
    end

    const Found = {}
    if type(Value) == "table" then
        for _, Item in Value do
            const Target = ResolveReference(Copy, Item, Find)
            if Target then
                table.insert(Found, Target)
            end
        end
    end

    return table.freeze(Found)
end

-- What to store for a value someone wants to put in an Object property: a live
-- object, a local id, or nil to clear it. Returns nil and a reason when the
-- value cannot be held, so each caller can refuse the way its layer refuses --
-- a setter returns false, a transaction refuses the whole list.
--
-- The type constraint is checked here rather than in Properties:IsValid because
-- this is the first layer that can: a property knows its own value, not which
-- object carries it, and what a local id names depends on which copy is asking.
-- It is checked only when the target actually resolves. A dangling id is always
-- allowed -- refusing one would make a pack unrestorable in any order but the
-- one it happened to be written in.
--
-- Takes the copy rather than the object doing the referring, because the object
-- is not always there to take: Construct applies a create's initial values
-- before the object they belong to has been assembled, and the copy is what the
-- ids are read against in either case.
--
-- One item: the constraints are the property's own for an Object, the item
-- constraints for a Table of them.
const function ReferenceOne(
    Copy: Types.SceneInstanceId,
    Name: string,
    Constraints: any,
    Value: any,
    Find: Find
): (number?, string?)
    if Value == nil then
        return NO_TARGET
    end

    local Target: number

    if type(Value) == "number" then
        Target = Value
    elseif type(Value) == "table" and type((Value :: any).RuntimeId) == "number" then
        const Other = Value :: Types.Object
        if Other.Destroyed then
            return nil, `{Other.Name} has been destroyed`
        end

        -- The one hard constraint on a reference. A local id from another copy
        -- would name whatever happens to hold that id here, and after either
        -- scene is saved and loaded somewhere else it would name nothing at
        -- all. Cross-copy and cross-scene references are out of scope for the
        -- same reason.
        if Other.InstanceId ~= Copy then
            return nil, `{Other.Name} is in another copy, and a reference only names objects in the copy holding it`
        end

        Target = Other.LocalId
    else
        return nil, `a {typeof(Value)} is neither an object nor a local id`
    end

    if Target == NO_TARGET then
        return NO_TARGET
    end

    const Found = Find(Copy, Target)
    if Found and not Found.Destroyed and not AllowedType(Constraints, Found) then
        return nil, `{Name} may not point at a {Found.Name}`
    end

    return Target
end

-- The same for a whole property: one id for an Object, a frozen list of them
-- for a Table, every item read the way an Object property's value is and the
-- whole list refused for any one item that cannot be held. Nil clears either:
-- no target, or no items. Any other property type is not this function's to
-- answer.
const function Reference(
    Copy: Types.SceneInstanceId,
    Prop: PropertyTypes.Property<any>,
    Value: any,
    Find: Find
): (any?, string?)
    if Prop.Type ~= "Table" then
        return ReferenceOne(Copy, Prop.Name, Prop.Constraints, Value, Find)
    end

    if Value == nil then
        return table.freeze({})
    end

    -- An object is a table too, and one passed where its list was meant would
    -- otherwise be walked as an empty list and clear the property.
    if type(Value) ~= "table" or (Value :: any).RuntimeId ~= nil then
        return nil, `a {typeof(Value)} is not a list`
    end

    const Item = Prop.Constraints and Prop.Constraints.Item
    const List = table.create(#Value)

    for Index, Each in Value do
        if type(Index) ~= "number" then
            return nil, "a list has only numbered items"
        end

        const Target, Why = ReferenceOne(Copy, `{Prop.Name}[{Index}]`, Item, Each, Find)
        if Target == nil then
            return nil, Why
        end

        List[Index] = Target
    end

    return table.freeze(List)
end

-- A held value with every id in it rewritten by Map, for the places that move a
-- reference from one set of objects to another: a duplicate pointing at its
-- group's duplicates, a placed pack pointing at what the placement made. Map
-- answers nil for an id with nothing to stand for it, which leaves an Object
-- property where it is -- nil comes back, and the caller sets nothing -- and
-- drops the item from a Table.
const function Remap(Prop: PropertyTypes.Property<any>, Value: any, Map: (number) -> number?): any?
    if Prop.Type ~= "Table" then
        return if type(Value) == "number" then Map(Value) else nil
    end

    if type(Value) ~= "table" then
        return nil
    end

    const List = {}
    for _, Item in Value do
        const Instead = Map(Item)
        if Instead ~= nil then
            table.insert(List, Instead)
        end
    end

    return table.freeze(List)
end

-- A saved object's values split in two: the ones that can be applied as they
-- are, and the references, which cannot.
--
-- A reference holds a local id, and a pack being *placed* -- read into a copy
-- that already exists, rather than into a copy of its own -- is read under new
-- ids that its scene mints as it goes. The saved id means nothing there: at
-- best it names nothing, at worst it names whatever else in that copy happens
-- to answer to it, which would wire a pasted button to a door it has never met.
--
-- So they are held back, and written afterwards against a map of what the
-- placement actually made. Loading a pack as a whole new copy has no such
-- problem -- every object keeps the id it was saved with -- which is why this
-- is the placing path's alone.
const function SplitReferences(
    Values: {[PropertyTypes.PropertyIdentifier]: any}
): ({[PropertyTypes.PropertyIdentifier]: any}, {[PropertyTypes.PropertyIdentifier]: any}?)
    const Plain = {}
    local References: {[PropertyTypes.PropertyIdentifier]: any}? = nil

    for Id, Value in Values do
        const Registry = Properties:GetRegistry(Id)
        if Registry and PropertyTypes.HoldsReferences(Registry) then
            if not References then
                References = {}
            end

            (References :: any)[Id] = Value
            continue
        end

        Plain[Id] = Value
    end

    return Plain, References
end

-- What a setter hands to Prop:Set, for any property type. Everything but an
-- Object passes straight through, so a caller does not have to know which kind
-- it is holding -- there are four setters across the two sides and each one
-- forgetting this individually is how a reference would come to mean one thing
-- through a transaction and another through Object:Set.
const function Accept(
    Obj: Types.Object,
    Prop: PropertyTypes.Property<any>,
    Value: any,
    Find: Find
): (boolean, any)
    if not PropertyTypes.HoldsReferences(Prop) then
        return true, Value
    end

    const Target, Why = Reference(Obj.InstanceId, Prop, Value, Find)
    if Target == nil then
        Logger:Warn(`Cannot point {Obj.Name}.{Prop.Name} at that value: {Why}.`)
        return false, nil
    end

    return true, Target
end

-- An object's values as initial values for another of its type, which is what
-- duplicating one is. The value held, not the default: a property left at its
-- default has nothing to copy, and the new object starts at that default anyway.
const function Snapshot(Obj: Types.Object): {[PropertyTypes.PropertyIdentifier]: any}
    const Values = {}
    for PropertyId, Prop in Obj.Properties do
        if Prop.Value ~= nil then
            Values[PropertyId] = Prop.Value
        end
    end

    return Values
end

-- What a restored object keeps of its save without understanding it: records
-- the pack could not place at all, and values for properties its type no
-- longer lists. Construct skips the second kind -- rightly, an object carries
-- only its type's properties -- which used to mean removing a property from a
-- type and saving erased every value it held, silently. Kept as tagged bytes,
-- written back by a save and by nothing else. Nil when there is nothing.
const function Leftovers(Obj: Types.Object, Decompressed: any): {[PropertyTypes.PropertyIdentifier]: buffer}?
    local Kept: {[PropertyTypes.PropertyIdentifier]: buffer}? = nil

    if Decompressed.Unknown then
        Kept = table.clone(Decompressed.Unknown)
    end

    for PropertyId, Value in Decompressed.Properties do
        if Obj.Properties[PropertyId] then
            continue
        end

        -- Read against its registry, so the type is the one it was saved as.
        const Registry = Properties:GetRegistry(PropertyId)
        const Tagged = if Registry then Compressor:CompressValue(Registry.Type, Value, Registry.Constraints) else nil
        if not Tagged then
            continue
        end

        if not Kept then
            Kept = {}
        end

        (Kept :: {[PropertyTypes.PropertyIdentifier]: buffer})[PropertyId] = Tagged
    end

    return Kept
end

-- Releases every link an object holds. Links belong to the object rather than
-- to the instance they drive: hanging them off an AncestryChanged handler kept
-- every instance alive in a strongly keyed pool and never fired at all for an
-- object destroyed directly.
const function ReleaseLinks(Links: {[PropertyTypes.PropertyIdentifier]: Types.InstanceLink}?)
    if not Links then
        return
    end

    for _, Link in Links do
        if Link.Disconnect then
            Link.Disconnect()
        end
    end
end

return {
    -- Stamped on every clone an object owns, before it is parented, so the tag
    -- and the id replicate as part of the instance itself. The runtime id, not
    -- the persistent one: this pairs a part with one live object, and a
    -- persistent id names every copy of it at once.
    --
    -- The instance reference that rides alongside ObjectAdded and the join
    -- replay is a fast path, not a guarantee: a client that has not replicated
    -- the part yet -- because it announced itself mid-join, or because streaming
    -- has not brought that region in -- decodes the reference as nil, and
    -- nothing ever sends it again. Carrying the runtime id on the instance lets
    -- the client rebuild the link whenever the part does arrive.
    RuntimeAttribute = "PrismRuntimeId",
    ObjectTag = "PrismObject",

    BuildNameMap = BuildNameMap,
    GetProperty = GetProperty,
    OnChange = OnChange,

    BuildProperties = BuildProperties,
    ValidateLinks = ValidateLinks,
    BuildLinks = BuildLinks,
    ReleaseLinks = ReleaseLinks,
    Snapshot = Snapshot,
    Leftovers = Leftovers,

    NO_TARGET = NO_TARGET,
    ResolveReference = ResolveReference,
    ResolveValue = ResolveValue,
    Reference = Reference,
    Remap = Remap,
    Accept = Accept,
    SplitReferences = SplitReferences,

    -- Reading or destroying an already destroyed object answers instead of
    -- throwing. The previous noop raised an error, which meant a stale
    -- reference could not even be checked and Destroy was not idempotent.
    Destroyed = {
        Get = function(): any?
            return nil
        end,

        Set = function(): boolean
            return false
        end,

        GetProperty = function(): PropertyTypes.Property<any>?
            return nil
        end,

        -- Still a disconnect function, so a caller that watches a stale object
        -- and later releases the listener does not fail on the release.
        OnChange = function(): () -> ()
            return NoDisconnect
        end,

        Destroy = function() end,
    },
}
