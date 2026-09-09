--!strict
const Properties = require("../Properties/Server")
const Permissions = require("../Permissions/Server")
const PropertyTypes = require("../Properties/Types")
const Compressor = require("../Compressor")
const Network = require("./Network")
const Shared = require("./Shared")
const IdPool = require("../IdPool")
const Logger = require("../Logger")
const Types = require("./Types")

export type ObjectIdentifier = Types.ObjectIdentifier
export type InstanceLinkRegistry = Types.InstanceLinkRegistry
export type InstanceLink = Types.InstanceLink
export type ObjectRegistry = Types.ObjectRegistry
export type ObjectConfig = Types.ObjectConfig
export type RuntimeId = Types.RuntimeId
export type Object = Types.Object

const MAX_RUNTIME_ID = 4294967295

const Objects = {}
local RuntimeCounter = 0

const Registered: {[ObjectIdentifier]: ObjectRegistry} = {}
const Workspace: {[RuntimeId]: Object} = {}
-- Never recycled, for the same reason property ids are not: a registry id is
-- written into every saved object as its Parent, so handing the same id to a
-- different object type later makes every stored object of the old type decode
-- as the new one.
const Ids = IdPool.new(nil, false)

-- ReflectionService is plugin security, so a live server cannot call it. Reading
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

-- Links are checked once, against the template, at registration. Every clone has
-- the same class and the same members, so the answer never differs between them
-- -- but these checks used to run inside Objects.new, which meant one malformed
-- link warned once for every object ever created from that registry.
const function ValidateLinks(
    Name: string,
    Target: Instance?,
    Links: {InstanceLinkRegistry}?,
    PropertyIds: {PropertyTypes.PropertyIdentifier}
): {InstanceLinkRegistry}?
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

const function GeneratePropertyMap(Props: {PropertyTypes.PropertyIdentifier}): {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>}
    const Map = {}
    for _, Identifier in Props do
        Map[Identifier] = Properties.new(Identifier)
    end

    return Map
end

-- Wiring only. ValidateLinks has already rejected anything that cannot work and
-- every clone shares the template's shape, so this no longer warns about link
-- shape -- it would repeat the same message once per object. The pcall stays
-- because the clone is not literally the instance that was validated.
const function GenerateLinksMap(
    Target: Instance?,
    Links: {InstanceLinkRegistry}?,
    Props: {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>}
): {[PropertyTypes.PropertyIdentifier]: InstanceLink}?
    if not Links or not Target then
        return nil
    end

    const Map = {}
    local Count = 0

    for _, Registry in Links do
        const Link: InstanceLink = table.clone(Registry) :: any
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

const function __getter(self: Object, Reference: Types.PropertyReference): any?
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return nil
    end

    return if Prop.Value == nil then Prop.DefaultValue else Prop.Value
end

const function __setter(self: Object, Reference: Types.PropertyReference, Value: any?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    const Accepted, Changed = Prop:Set(Value)
    if not Accepted then
        return false
    end

    if Changed then
        const Compressed = Compressor:CompressValue(Prop.Type, Prop.Value)
        if Compressed then
            Network.PropertyChanged:FireAll(self.RuntimeId, Prop.Parent, Compressed)
        end
    end

    return true
end

const function __destroy(self: Object)
    if self.Destroyed then
        return
    end

    self.Destroyed = true

    -- Links used to be torn down from an AncestryChanged handler on the linked
    -- instance, which kept every instance alive in a strongly keyed pool and
    -- never fired for objects destroyed directly. They belong to the object.
    if self.Links then
        for _, Link in self.Links do
            if Link.Disconnect then
                Link.Disconnect()
            end
        end

        self.Links = nil
    end

    for _, Prop in self.Properties do
        Prop:Destroy()
    end

    if self.Instance then
        self.Instance:Destroy()
        self.Instance = nil
    end

    if Workspace[self.RuntimeId] then
        Workspace[self.RuntimeId] = nil
        Network.ObjectRemoved:FireAll(self.RuntimeId)
    end

    self.Get = Shared.Destroyed.Get
    self.Set = Shared.Destroyed.Set
    self.GetProperty = Shared.Destroyed.GetProperty
    self.OnChange = Shared.Destroyed.OnChange
    self.Destroy = Shared.Destroyed.Destroy
end

-- The client only needs the shape of a registry, never the template instance or
-- the link table, so neither goes over the wire.
const function ToRegistryPayload(Registry: ObjectRegistry)
    return {
        Id = Registry.Id,
        Name = Registry.Name,
        Properties = Registry.Properties,
    }
end

function Objects:Register(Config: ObjectConfig): ObjectIdentifier?
    const Requested = if Config.CustomId ~= nil
        then IdPool.Normalize(Config.CustomId, "object")
        else nil

    const Identifier = Ids:Claim(Requested)
    if not Identifier then
        Logger:Warn(`There's already an object registered with id {Requested}.`)
        return
    end

    -- A clone with no Container is never parented, so it is not replicated and
    -- the Instance the client receives with ObjectAdded is nil -- which also
    -- means FromInstance can never resolve these objects.
    if Config.Instance and not Config.Container then
        Logger:Warn(`Object {Config.Name} has an Instance but no Container, so its clones will not replicate to clients.`)
    end

    const Valid = {}
    for _, PropId in Config.Properties do
        if Properties:GetRegistry(PropId) then
            table.insert(Valid, PropId)
        else
            Logger:Warn(`Object {Config.Name} references unregistered property {PropId}. Will be skipped.`)
        end
    end

    const Obj: ObjectRegistry = {
        Id = Identifier,
        Name = Config.Name,
        Properties = Valid,
        Instance = Config.Instance,
        Container = Config.Container,
        Links = ValidateLinks(Config.Name, Config.Instance, Config.Links, Valid),
    }

    Registered[Identifier] = Obj
    Network.ObjectRegistered:FireAll(ToRegistryPayload(Obj))
    return Identifier
end

function Objects:GetWorkspace(): {[RuntimeId]: Object}
    return Workspace
end

function Objects:GetRegistered(): {[ObjectIdentifier]: ObjectRegistry}
    return Registered
end

function Objects:GetRegistry(Identifier: ObjectIdentifier): ObjectRegistry?
    return Registered[Identifier]
end

function Objects:GetRegistryPayload(Identifier: ObjectIdentifier)
    const Registry = Registered[Identifier]
    return if Registry then ToRegistryPayload(Registry) else nil
end

-- InitialValues are applied before the links are wired and before the broadcast.
-- Restoring a saved object used to call Objects.new and then Set once per
-- property, which broadcast the defaults and then one PropertyChanged for each
-- property -- a 500 object level at ten properties each cost several thousand
-- packets, and every object's first packet carried state that was already wrong.
function Objects.new(
    Reference: ObjectRegistry | ObjectIdentifier,
    InitialValues: {[PropertyTypes.PropertyIdentifier]: any}?
): Object
    const TypeOf = typeof(Reference)
    local Ref: ObjectRegistry

    if TypeOf == "number" then
        Ref = Registered[Reference :: ObjectIdentifier]
        if not Ref then
            Logger:Error(`Invalid object reference. No object registered with id {Reference}.`)
        end
    elseif TypeOf == "table" then
        Ref = Reference :: ObjectRegistry
    else
        Logger:Error(`Invalid object reference. Expected a registry or an id, got {TypeOf}.`)
    end

    if not Ref or not Ref.Id or not Registered[Ref.Id] then
        Logger:Error("Invalid object reference. The registry it points at is not registered.")
    end

    if RuntimeCounter >= MAX_RUNTIME_ID then
        Logger:Error("Runtime id space exhausted.")
    end

    RuntimeCounter += 1

    -- The registry instance is a template. Handing the same one to every object
    -- meant they all drove the same part, and destroying any one of them took
    -- the part away from the rest.
    local Inst: Instance? = nil
    if Ref.Instance then
        Inst = Ref.Instance:Clone()
        if Ref.Container then
            (Inst :: Instance).Parent = Ref.Container
        end
    end

    const Props = GeneratePropertyMap(Ref.Properties)
    if InitialValues then
        for PropertyId, Value in InitialValues do
            const Prop = Props[PropertyId]
            if Prop then
                Prop:Set(Value)
            end
        end
    end

    const Obj = {}
    Obj.RuntimeId = RuntimeCounter
    Obj.Parent = Ref.Id
    Obj.Name = Ref.Name
    Obj.Destroyed = false
    Obj.Properties = Props
    Obj.Names = Shared.BuildNameMap(Ref.Properties, Props)
    Obj.Instance = Inst
    -- Wired after the initial values land, so a link starts at the object's real
    -- value rather than the registry default and then being corrected.
    Obj.Links = GenerateLinksMap(Inst, Ref.Links, Props)
    Obj.Get = __getter
    Obj.Set = __setter
    Obj.GetProperty = Shared.GetProperty
    Obj.OnChange = Shared.OnChange
    Obj.Destroy = __destroy

    Workspace[Obj.RuntimeId] = Obj

    -- Only the compressed values go out. Firing the live object sent Property
    -- tables carrying Set/SetDefault functions and links carrying connections,
    -- neither of which a remote can serialize, so this threw every time.
    Network.ObjectAdded:FireAll(Obj.RuntimeId, Compressor:CompressObject(Obj :: any), Inst)
    return Obj :: any
end

function Objects.fromCompression(CompressedObj: buffer): Object?
    const Ok, Decompressed = pcall(function()
        return Compressor:DecompressObject(CompressedObj)
    end)

    if not Ok or not Decompressed then
        Logger:Warn("Failed to create object from compression.")
        return nil
    end

    if not Registered[Decompressed.Parent] then
        Logger:Warn(`Failed to create object from compression. Object {Decompressed.Parent} is not registered.`)
        return nil
    end

    return Objects.new(Decompressed.Parent, Decompressed.Properties)
end

Network.SetProperty.OnInvoke = function(Plr: Player, RuntimeId: RuntimeId, PropId: PropertyTypes.PropertyIdentifier, Compressed: buffer): boolean
    -- Budget first. Check used to run after the workspace lookup, so a client
    -- spamming runtime ids that do not exist returned early and never spent any
    -- of its allowance -- the one flood the limiter most needed to catch.
    if not Permissions:Consume(Plr) then
        return false
    end

    const Obj = Workspace[RuntimeId]
    if not Obj or Obj.Destroyed then
        return false
    end

    if not Permissions:Can(Plr, "Edit", Obj.Parent) then
        return false
    end

    const Prop = Obj.Properties[PropId]
    if not Prop then
        return false
    end

    -- The payload is self describing, so this also confirms the client sent the
    -- type the property actually expects rather than trusting it to.
    const Ok, Value, Type = pcall(function()
        const Decoded, _, DecodedType = Compressor:DecompressValue(Compressed, 0)
        return Decoded, DecodedType
    end)

    if not Ok or Type ~= Prop.Type then
        return false
    end

    return Obj:Set(PropId, Value)
end

Network.Destroy.OnInvoke = function(Plr: Player, RuntimeId: RuntimeId): boolean
    if not Permissions:Consume(Plr) then
        return false
    end

    const Obj = Workspace[RuntimeId]
    if not Obj or Obj.Destroyed then
        return false
    end

    if not Permissions:Can(Plr, "Destroy", Obj.Parent) then
        return false
    end

    Obj:Destroy()
    return true
end

return Objects
