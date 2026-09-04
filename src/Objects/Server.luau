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
const Ids = IdPool.new()

-- ReflectionService is plugin security, so a live server cannot call it. Reading
-- the property is enough to learn both whether it exists and what type it is.
const function GetInstancePropertyType(Inst: Instance, Name: string): string?
    const Ok, Value = pcall(function()
        return (Inst :: any)[Name]
    end)

    return if Ok then typeof(Value) else nil
end

const function GeneratePropertyMap(Props: {PropertyTypes.PropertyIdentifier}): {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>}
    const Map = {}
    for _, Identifier in Props do
        Map[Identifier] = Properties.new(Identifier)
    end

    return Map
end

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
            Logger:Warn(`Invalid link. Property {Link.Property} is not registered for this object.`)
            continue
        end

        const Inst = if Link.Descendant
            then Target:FindFirstChild(Link.Descendant, true)
            else Target

        if not Inst then
            Logger:Warn(`Invalid link. {Target.Name} has no descendant named {Link.Descendant}.`)
            continue
        end

        if Link.Type == "Property" then
            const Actual = GetInstancePropertyType(Inst, Link.Name)
            if not Actual then
                Logger:Warn(`Invalid link. {Inst.ClassName} has no property named {Link.Name}.`)
                continue
            end

            -- Types.Map translates a Loom type name to the Roblox one. The old
            -- comparison held these side by side raw, so "Vector" was tested
            -- against "Vector3" and every property link failed.
            const Expected = PropertyTypes.Map[Prop.Type]
            if Actual ~= Expected then
                Logger:Warn(`Invalid link. {Inst.ClassName}.{Link.Name} is {Actual}, but property {Prop.Name} is {Expected}.`)
                continue
            end

            if Prop.Value ~= nil then
                (Inst :: any)[Link.Name] = Prop.Value
            end

            Link.Disconnect = Prop:OnChange(function(Value)
                (Inst :: any)[Link.Name] = Value
            end)
        elseif Link.Type == "Attribute" then
            Inst:SetAttribute(Link.Name, Prop.Value)
            Link.Disconnect = Prop:OnChange(function(Value)
                Inst:SetAttribute(Link.Name, Value)
            end)
        else
            Logger:Warn(`Invalid link. Type {Link.Type} is not valid.`)
            continue
        end

        Map[Link.Property] = Link
        Count += 1
    end

    return if Count > 0 then Map else nil
end

const function __getter(self: Object, Reference: PropertyTypes.PropertyIdentifier | string): any?
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return nil
    end

    return if Prop.Value == nil then Prop.DefaultValue else Prop.Value
end

const function __setter(self: Object, Reference: PropertyTypes.PropertyIdentifier | string, Value: any?): boolean
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
        Links = Config.Links,
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

function Objects.new(Reference: ObjectRegistry | ObjectIdentifier): Object
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

    const Obj = {}
    Obj.RuntimeId = RuntimeCounter
    Obj.Parent = Ref.Id
    Obj.Name = Ref.Name
    Obj.Destroyed = false
    Obj.Properties = GeneratePropertyMap(Ref.Properties)
    Obj.Instance = Inst
    Obj.Links = GenerateLinksMap(Inst, Ref.Links, Obj.Properties)
    Obj.Get = __getter
    Obj.Set = __setter
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

    const Obj = Objects.new(Decompressed.Parent)
    for PropertyId, Value in Decompressed.Properties do
        Obj:Set(PropertyId, Value)
    end

    return Obj
end

Network.SetProperty.OnInvoke = function(Plr: Player, RuntimeId: RuntimeId, PropId: PropertyTypes.PropertyIdentifier, Compressed: buffer): boolean
    const Obj = Workspace[RuntimeId]
    if not Obj or Obj.Destroyed then
        return false
    end

    if not Permissions:Check(Plr, "Edit", Obj.Parent) then
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
    const Obj = Workspace[RuntimeId]
    if not Obj or Obj.Destroyed then
        return false
    end

    if not Permissions:Check(Plr, "Destroy", Obj.Parent) then
        return false
    end

    Obj:Destroy()
    return true
end

return Objects
