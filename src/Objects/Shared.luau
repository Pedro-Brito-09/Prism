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

const Properties = if RunService:IsClient()
    then require("../Properties/Client")
    else require("../Properties/Server")

const PropertyTypes = require("../Properties/Types")
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
