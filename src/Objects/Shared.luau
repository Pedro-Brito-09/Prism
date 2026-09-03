const PropertyTypes = require("../Properties/Types")
const Logger = require("../Logger")
const Types = require("./Types")

return {
    GetProperty = function(self: Types.Object, Reference: PropertyTypes.PropertyIdentifier | string): PropertyTypes.Property?
        for _, v in self.Properties do
            if v.Name == Reference or v.Parent == Reference then
                return v
            end
        end

        return
    end,

    FindObject = function(Workspace: {Types.Object}, RuntimeId: number): Types.Object?
        for _, Obj in Workspace do
            if Obj.RuntimeId == RuntimeId then
                return Obj
            end
        end

        return
    end,

    __destroyed_noop = function()
        Logger:Error("This object has been destroyed.")
    end
}