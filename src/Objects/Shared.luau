--!strict
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

return {
    BuildNameMap = BuildNameMap,
    GetProperty = GetProperty,
    OnChange = OnChange,

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
