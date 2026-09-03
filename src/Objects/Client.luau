const PropertyTypes = require("../Properties/Types")
const Network = require("./Network")
const Shared = require("./Shared")
const Types = require("./Types")

export type ObjectIdentifier = Types.ObjectIdentifier
export type ObjectRegistry = Types.ObjectRegistry
export type RuntimeId = Types.RuntimeId
export type Object = Types.Object

const Objects = {}

const Registered: {[ObjectIdentifier]: ObjectRegistry} = {}
const Workspace: {[RuntimeId]: Object} = {}

const function __getter(self: Object, Reference: PropertyTypes.PropertyIdentifier | string): any?
    local Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return
    end

    return if Prop.Value == nil then Prop.DefaultValue else Prop.Value
end

const function __setter(self: Object, Reference: PropertyTypes.PropertyIdentifier | string, Value: any?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    return Network.SetProperty:Invoke(self.RuntimeId, Prop.Parent, Value)
end

const function __destroy(self: Object): boolean
    return Network.Destroy:Invoke(self.RuntimeId)
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

Network.ObjectRegistered:Connect(function(Obj)
    Registered[Obj.Id] = Obj
end)

Network.ObjectAdded:Connect(function(Obj: Object)
    Obj.Get = __getter
    Obj.Set = __setter
    Obj.Destroy = __destroy
    Workspace[Obj.RuntimeId] = Obj
end)

Network.ObjectRemoved:Connect(function(ObjId: number)
    const Obj = Workspace[ObjId]
    if Obj then
        Workspace[ObjId] = nil

        table.clear(Obj)
        Obj.Get = Shared.__destroyed_noop
        Obj.Set = Shared.__destroyed_noop
        Obj.Destroy = Shared.__destroyed_noop
    end
end)

Network.PropertyChanged:Connect(function(ObjId: number, Property: PropertyTypes.PropertyIdentifier, Value: any?)
    const Obj = Workspace[ObjId]
    if not Obj then
        return
    end

    const Prop = Obj.Properties[Property]
    if not Prop then
        return
    end

    Prop.Value = Value
end)

return Objects