--!strict
const PropertyTypes = require("../Properties/Types")
const Types = require("./Types")

return {
    GetProperty = function(self: Types.Object, Reference: PropertyTypes.PropertyIdentifier | string): PropertyTypes.Property<any>?
        if type(Reference) == "number" then
            return self.Properties[Reference]
        end

        for _, Prop in self.Properties do
            if Prop.Name == Reference then
                return Prop
            end
        end

        return nil
    end,

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

        Destroy = function() end,
    },
}
