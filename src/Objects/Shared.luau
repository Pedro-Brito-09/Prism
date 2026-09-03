const PropertyTypes = require("../Properties/Types")
const Logger = require("../Logger")
const Types = require("./Types")

return {
    GetProperty = function(self: Types.Object, Reference: PropertyTypes.PropertyIdentifier | string): PropertyTypes.Property?
        if type(Reference) == "number" then
            return self.Properties[Reference]
        end

        for _, v in self.Properties do
            if v.Name == Reference then
                return v
            end
        end

        return
    end,

    __destroyed_noop = function()
        Logger:Error("This object has been destroyed.")
    end
}