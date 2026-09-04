--!strict
const Properties = require("../Properties/Client")
const PropertyTypes = require("../Properties/Types")
const Compressor = require("../Compressor")
const Network = require("./Network")
const Shared = require("./Shared")
const Logger = require("../Logger")
const Types = require("./Types")

export type ObjectIdentifier = Types.ObjectIdentifier
export type ObjectRegistry = Types.ObjectRegistry
export type RuntimeId = Types.RuntimeId
export type Object = Types.Object

const Objects = {}

const Registered: {[ObjectIdentifier]: ObjectRegistry} = {}
const Workspace: {[RuntimeId]: Object} = {}
const ByInstance: {[Instance]: RuntimeId} = setmetatable({}, {__mode = "k"}) :: any

const function __getter(self: Object, Reference: PropertyTypes.PropertyIdentifier | string): any?
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return nil
    end

    return if Prop.Value == nil then Prop.DefaultValue else Prop.Value
end

-- Applies locally first, then confirms with the server on a separate thread. The
-- previous version blocked the caller on a RemoteFunction for every single set,
-- which in an editor means a yield per axis per frame while dragging.
--
-- If the server refuses (permissions, validation) the local value rolls back.
-- If it accepts, its PropertyChanged broadcast reasserts the authoritative value.
const function __setter(self: Object, Reference: PropertyTypes.PropertyIdentifier | string, Value: any?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    const Previous = Prop.Value
    const Accepted, Changed = Prop:Set(Value)
    if not Accepted then
        return false
    end

    -- Setting a property to the value it already holds is a no-op, not a reason
    -- to spend a round trip.
    if not Changed then
        return true
    end

    const Compressed = Compressor:CompressValue(Prop.Type, Prop.Value)
    if not Compressed then
        return false
    end

    const RuntimeId = self.RuntimeId
    const PropId = Prop.Parent

    task.spawn(function()
        const Ok, Allowed = pcall(function()
            return Network.SetProperty:Invoke(RuntimeId, PropId, Compressed)
        end)

        if (not Ok or not Allowed) and not self.Destroyed then
            Prop:Set(Previous)
        end
    end)

    return true
end

const function __destroy(self: Object): boolean
    if self.Destroyed then
        return false
    end

    const Ok, Allowed = pcall(function()
        return Network.Destroy:Invoke(self.RuntimeId)
    end)

    return Ok and Allowed == true
end

const function Teardown(Obj: Object)
    if Obj.Destroyed then
        return
    end

    Obj.Destroyed = true

    for _, Prop in Obj.Properties do
        Prop:Destroy()
    end

    if Obj.Instance then
        ByInstance[Obj.Instance] = nil
        Obj.Instance = nil
    end

    -- Not table.clear: a stale reference should still be able to report its own
    -- runtime id and read Destroyed rather than turning into an empty table
    -- whose every method throws.
    Obj.Get = Shared.Destroyed.Get
    Obj.Set = Shared.Destroyed.Set
    Obj.Destroy = Shared.Destroyed.Destroy
end

function Objects:GetWorkspace(): {[RuntimeId]: Object}
    return Workspace
end

function Objects:Get(RuntimeId: RuntimeId): Object?
    return Workspace[RuntimeId]
end

function Objects:GetRegistered(): {[ObjectIdentifier]: ObjectRegistry}
    return Registered
end

function Objects:GetRegistry(Identifier: ObjectIdentifier): ObjectRegistry?
    return Registered[Identifier]
end

-- Editor convenience: turn a clicked part back into the object that owns it.
function Objects:FromInstance(Inst: Instance): Object?
    local Current: Instance? = Inst
    while Current do
        const RuntimeId = ByInstance[Current]
        if RuntimeId then
            return Workspace[RuntimeId]
        end

        Current = Current.Parent
    end

    return nil
end

Network.ObjectRegistered:Connect(function(Registry: ObjectRegistry)
    Registered[Registry.Id] = Registry
end)

Network.ObjectAdded:Connect(function(RuntimeId: RuntimeId, Compressed: buffer, Inst: Instance?)
    const Ok, Data = pcall(function()
        return Compressor:DecompressObject(Compressed)
    end)

    if not Ok or not Data then
        Logger:Warn(`Failed to decompress object {RuntimeId}.`)
        return
    end

    const Registry = Registered[Data.Parent]
    if not Registry then
        Logger:Warn(`Received object {RuntimeId} for unregistered type {Data.Parent}.`)
        return
    end

    const Obj = {}
    Obj.RuntimeId = RuntimeId
    Obj.Parent = Data.Parent
    Obj.Name = Registry.Name
    Obj.Destroyed = false
    Obj.Instance = Inst
    Obj.Links = nil
    Obj.Properties = {}

    for _, PropId in Registry.Properties do
        const Prop = Properties.new(PropId)
        if Data.Properties[PropId] ~= nil then
            Prop:Set(Data.Properties[PropId])
        end

        Obj.Properties[PropId] = Prop
    end

    Obj.Get = __getter
    Obj.Set = __setter
    Obj.Destroy = __destroy

    Workspace[RuntimeId] = Obj
    if Inst then
        ByInstance[Inst] = RuntimeId
    end
end)

Network.ObjectRemoved:Connect(function(RuntimeId: RuntimeId)
    const Obj = Workspace[RuntimeId]
    if not Obj then
        return
    end

    Workspace[RuntimeId] = nil
    Teardown(Obj)
end)

Network.PropertyChanged:Connect(function(RuntimeId: RuntimeId, PropId: PropertyTypes.PropertyIdentifier, Compressed: buffer)
    const Obj = Workspace[RuntimeId]
    if not Obj then
        return
    end

    const Prop = Obj.Properties[PropId]
    if not Prop then
        return
    end

    const Ok, Value, Type = pcall(function()
        const Decoded, _, DecodedType = Compressor:DecompressValue(Compressed, 0)
        return Decoded, DecodedType
    end)

    if Ok and Type == Prop.Type then
        Prop:Set(Value)
    end
end)

return Objects
