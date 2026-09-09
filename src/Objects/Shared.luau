--!strict
const PropertyTypes = require("../Properties/Types")
const Types = require("./Types")

return {
    -- Stamped on every clone an object owns, before it is parented, so the tag
    -- and the id replicate as part of the instance itself.
    --
    -- The instance reference that rides alongside ObjectAdded and the join
    -- replay is a fast path, not a guarantee: a client that has not replicated
    -- the part yet -- because it announced itself mid-join, or because streaming
    -- has not brought that region in -- decodes the reference as nil, and
    -- nothing ever sends it again. Carrying the runtime id on the instance lets
    -- the client rebuild the link whenever the part does arrive.
    RuntimeAttribute = "PrismRuntimeId",
    ObjectTag = "PrismObject",

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
