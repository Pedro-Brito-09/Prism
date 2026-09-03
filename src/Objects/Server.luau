const ReflectionService = game:GetService("ReflectionService")

const Properties = require("../Properties/Server")
const Compressor = require("../Compressor")
const Network = require("./Network")
const Shared = require("./Shared")
const Logger = require("../Logger")
const Types = require("./Types")

export type ObjectIdentifier = Types.ObjectIdentifier
export type InstanceLinkRegistry = Types.InstanceLinkRegistry
export type InstanceLink = Types.InstanceLink
export type ObjectRegistry = Types.ObjectRegistry
export type ObjectConfig = Types.ObjectConfig
export type Object = Types.Object

const Objects = {}
local RuntimeCounter = 0

const Registered: {[ObjectIdentifier]: ObjectRegistry} = {}
const Workspace: {Object} = {}
const LinkedPool: {
    [Instance]: {
        Connection: RBXScriptConnection,
        Links: {InstanceLink},
    }
} = {}

const function AddLinkToDisconnectPool(Link: InstanceLink, Instance: Instance)
    if not Link.OnChange then
        return
    end

    if not LinkedPool[Instance] then
        LinkedPool[Instance] = {
            Links = {},
            Connection = Instance.AncestryChanged:Connect(function()
                if not Instance:IsDescendantOf(game) then
                    if Instance.RobloxLocked then
                        for _, Link in LinkedPool[Instance].Links do
                            if Link.OnChange then
                                Link.OnChange:Destroy()
                            end
                        end

                        LinkedPool[Instance].Connection:Disconnect()
                        LinkedPool[Instance] = nil
                    else
                        for _, Link in LinkedPool[Instance].Links do
                            if Link.OnChange then
                                Link.OnChange:Disconnect()
                            end
                        end
                    end
                elseif LinkedPool[Instance] then
                    for _, Link in LinkedPool[Instance].Links do
                        if Link.OnChange then
                            Link.OnChange:Reconnect()
                        end
                    end
                end
            end)
        }
    end

    table.insert(LinkedPool[Instance].Links, Link)
end

const function GetNextFreeId(): number
    local MinNextFree;
    for i, v in Registered do
        if (not MinNextFree or i < MinNextFree) and not Registered[i + 1] then
            MinNextFree = i
        end
    end

    return MinNextFree + 1 or 1
end

const function GeneratePropertyMap(Props: {Properties.PropertyIdentifier}): {[Properties.PropertyIdentifier]: Properties.Property}
    const Map = {}
    for _, Identifier in Props do
        Map[Identifier] = Properties.new(Identifier)
    end

    return Map
end

const function GenerateLinksMap(Instance: Instance?, Links: {InstanceLinkRegistry}?, Props: {[Properties.PropertyIdentifier]: Properties.Property}): {[Properties.PropertyIdentifier]: InstanceLink}?
    const Map = {}
    if not Links or not Instance then
        return
    end

    local Count = 0
    for _, Link in Links do
        const Prop = Props[Link.Property]
        if not Prop then
            Logger:Warn(`Invalid link reference. Property {Link.Property} is not registered for this object.`)
            continue
        end

        if Prop.Type == "Table" then
            Logger:Warn(`Invalid link reference. Property {Link.Property} is of type Table, which cannot be linked.`)
            continue
        end

        const Inst = Link.Descendant or Instance
        if Link.Type == "Property" then
            local InstProps = ReflectionService:GetPropertiesOfClass(Inst.ClassName)
            local Found = false
            for _, v in InstProps do
                if v.Name == Link.Name then
                    if v.Type ~= Prop.Type then
                        Logger:Warn(`Invalid link reference. {Inst.ClassName}'s property {Link.Name} is of type {v.Type} but you registered yours as {Prop.Type}.`)
                        continue
                    end

                    Inst[Link.Name] = Prop:Get()
                    Link.OnChange = Prop.Changed:Connect(function(Value)
                        Inst[Link.Name] = Value
                    end)

                    Found = true
                    break
                end
            end

            if not Found then
                Logger:Warn(`Invalid link reference. {Inst.ClassName} does not have a property named {Link.Name}.`)
                continue
            end
        elseif Link.Type == "Attribute" then
            Inst:SetAttribute(Link.Name, Prop:Get())
            Link.OnChange = Prop.Changed:Connect(function(Value)
                Inst:SetAttribute(Link.Name, Value)
            end)
        else
            Logger:Warn(`Invalid link reference. Type {Link.Type} is not valid.`)
            continue
        end

        AddLinkToDisconnectPool(Link, Inst)
        Map[Link.Property] = Link
        Count += 1
    end

    return Count > 0 and Map or nil
end

const function __getter(self: Object, Reference: Properties.PropertyIdentifier | string): any?
    local Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return
    end

    return if Prop.Value == nil then Prop.DefaultValue else Prop.Value
end

const function __setter(self: Object, Reference: Properties.PropertyIdentifier | string, Value: any?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    const Success = Prop:Set(Value)
    if Success then
        Network.PropertyChanged:FireAll(self.RuntimeId, Prop.Parent, Value)
    end

    return Success
end

const function __destroy(self: Object)
    if self.Instance then
        self.Instance:Destroy()
    end

    const Position = table.find(Workspace, self)
    if Position then
        table.remove(Workspace, Position)
        Network.ObjectRemoved:FireAll(self)
    end

    table.clear(self)
    self.Get = Shared.__destroyed_noop
    self.Set = Shared.__destroyed_noop
    self.Destroy = Shared.__destroyed_noop
end

function Objects:Register(Config: ObjectConfig): ObjectIdentifier?
    if Config.CustomId then
        local Number = tonumber(Config.CustomId)
        if not Number then
            Logger:Warn(`Custom object id needs to be an integer, got {Config.CustomId}. Will be using the next free id instead.`)
            Config.CustomId = nil
        elseif Number ~= math.floor(Number) then
            Logger:Warn(`Custom object id needs to be an integer, got {Config.CustomId}. Will be using {math.floor(Number)} instead.`)
            Config.CustomId = math.floor(Number)
        end
    end

    const Identifier = Config.CustomId or GetNextFreeId()
    if Registered[Identifier] then
        Logger:Warn(`There's already an object registered with id {Identifier}.`)
        return
    end

    const Obj = {}
    Obj.Id = Identifier
    Obj.Name = Config.Name
    Obj.Properties = Config.Properties
    Obj.Instance = Config.Instance
    Obj.Links = Config.Links

    Registered[Identifier] = Obj
    Network.ObjectRegistered:FireAll(Obj)
    return Identifier
end

function Objects:GetWorkspace(): {Object}
    return Workspace
end

function Objects:GetRegistered(): {[ObjectIdentifier]: ObjectRegistry}
    return Registered
end

function Objects:GetRegistry(Identifier: ObjectIdentifier): ObjectRegistry?
    return Registered[Identifier]
end

function Objects.new(Reference: ObjectRegistry | ObjectIdentifier): Object
    const TypeOf = typeof(Reference)
    local Ref: ObjectRegistry
    if TypeOf == "number" then
        if not Registered[Reference :: ObjectIdentifier] then
            error(`[CREATE UTILS] Invalid object reference.`)
        end

        Ref = Registered[Reference :: ObjectIdentifier]
    elseif TypeOf == "table" then
        Ref = Reference :: ObjectRegistry
    else
        error(`[CREATE UTILS] Invalid object reference.`)
    end

    if not Ref or not Ref.Id or not Registered[Ref.Id] then
        error(`[CREATE UTILS] Invalid object reference.`)
    end

    RuntimeCounter += 1

    const Obj = {}
    Obj.RuntimeId = RuntimeCounter
    Obj.Parent = Ref.Id
    Obj.Name = Ref.Name
    Obj.Properties = GeneratePropertyMap(Ref.Properties)
    Obj.Instance = Ref.Instance
    Obj.Links = GenerateLinksMap(Ref.Instance, Ref.Links, Obj.Properties)
    Obj.Get = __getter
    Obj.Set = __setter
    Obj.Destroy = __destroy

    table.insert(Workspace, Obj)
    Network.ObjectAdded:FireAll(Obj)
    return Obj
end

function Objects.fromCompression(CompressedObj: buffer): Object?
    const DecompressedObj = Compressor:DecompressObject(CompressedObj)
    if not DecompressedObj then
        Logger:Warn("Failed to create object from compression.")
        return
    end

    const Registry = Objects:GetRegistry(DecompressedObj.Parent)
    if not Registry then
        Logger:Warn(`Failed to create object from compression. Object {DecompressedObj.Parent} is not registered.`)
        return
    end

    const Obj = Objects.new(DecompressedObj.Parent)
    for PropertyId, Value in DecompressedObj.Properties do
        Obj:Set(PropertyId, Value)
    end

    return Obj
end

Network.SetProperty.OnInvoke = function(ObjId: ObjectIdentifier, PropId: Properties.PropertyIdentifier, Value: any?): boolean
    const Obj = Shared.FindObject(Workspace, ObjId)
    if not Obj then
        return false
    end

    const Prop = Obj.Properties[PropId]
    if not Prop then
        return false
    end

    return Prop:Set(Value)
end

return Objects