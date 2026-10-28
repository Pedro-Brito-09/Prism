--!strict
-- The parts of a permission check that are the same on both sides.
--
-- The server decides and the client only asks, to grey out a tool before a
-- request is refused. Both have to reach the same answer from the same rights,
-- or an editor shows a tool the server will not honour -- so the lists a role
-- is written with become sets here, the check is written once here, and so is
-- the wire form.

const Types = require("./Types")

const Shared = {}

-- Actions per second for anyone with no global grant. Scene rights fail closed
-- without a grant; the budget does not, because it is a ceiling on requests
-- rather than a right, and every request it lets through still meets a scene
-- that has granted nothing.
Shared.DEFAULT_RATE = 60

const function IdSet(List: {any}?): {[number]: true}
    const Set = {}
    for _, Id in List or {} do
        if type(Id) == "number" then
            Set[Id] = true
        end
    end

    return Set
end

-- Both forms of a property list can sit in one list: a number value is a
-- property id, and a numeric key holding true or a list of types is a property
-- limited to those types.
const function PropertySet(List: {[any]: any}?): {[number]: Types.PropertyEntry}
    const Set: {[number]: Types.PropertyEntry} = {}
    for Key, Value in List or {} do
        if type(Value) == "number" then
            Set[Value] = true
        elseif Value == true and type(Key) == "number" then
            Set[Key] = true
        elseif type(Value) == "table" and type(Key) == "number" then
            Set[Key] = IdSet(Value)
        end
    end

    return Set
end

const function CapabilitySet(List: {any}?): {[string]: true}
    const Set = {}
    for _, Name in List or {} do
        if type(Name) == "string" then
            Set[Name] = true
        end
    end

    return Set
end

function Shared.SceneRights(Config: Types.SceneRoleConfig?, Role: string?): Types.SceneRights
    const Given: Types.SceneRoleConfig = Config or {}
    const Objects = Given.Objects
    const Properties = Given.Properties

    return {
        Role = Role,
        CanCreate = Given.CanCreate == true,
        CanEdit = Given.CanEdit == true,
        CanDestroy = Given.CanDestroy == true,
        ObjectWhitelist = if Objects and Objects.Whitelist then IdSet(Objects.Whitelist) else nil,
        ObjectBlacklist = IdSet(if Objects then Objects.Blacklist else nil),
        PropertyWhitelist = if Properties and Properties.Whitelist then PropertySet(Properties.Whitelist) else nil,
        PropertyBlacklist = PropertySet(if Properties then Properties.Blacklist else nil),
        Capabilities = CapabilitySet(Given.Capabilities),
    }
end

function Shared.GlobalRights(Config: Types.GlobalRoleConfig?, Role: string?): Types.GlobalRights
    const Given: Types.GlobalRoleConfig = Config or {}

    return {
        Role = Role,
        Rate = Given.Rate or Shared.DEFAULT_RATE,
        CanPush = Given.CanPush == true,
        Capabilities = CapabilitySet(Given.Capabilities),
    }
end

-- A player's own set, taken from a role. The capabilities are copied because a
-- player's are granted and revoked one at a time; the lists are shared because
-- nothing ever changes them after the role is registered.
function Shared.CopyScene(Rights: Types.SceneRights): Types.SceneRights
    const Copy = table.clone(Rights)
    Copy.Capabilities = table.clone(Rights.Capabilities)
    return Copy
end

function Shared.CopyGlobal(Rights: Types.GlobalRights): Types.GlobalRights
    const Copy = table.clone(Rights)
    Copy.Capabilities = table.clone(Rights.Capabilities)
    return Copy
end

const function Listed(Set: {[number]: Types.PropertyEntry}, Property: number, ObjectType: number): boolean
    const Entry = Set[Property]
    if Entry == true then
        return true
    end

    return type(Entry) == "table" and Entry[ObjectType] == true
end

-- Verb, then the object lists, then -- for anything that writes a property --
-- the property lists. An unrecognised verb denies rather than falling through
-- to the allow path.
function Shared.Allows(Rights: Types.SceneRights, Action: string, ObjectType: number, Property: number?): boolean
    local Verb: boolean
    if Action == "Create" then
        Verb = Rights.CanCreate
    elseif Action == "Edit" then
        Verb = Rights.CanEdit
    elseif Action == "Destroy" then
        Verb = Rights.CanDestroy
    else
        return false
    end

    if not Verb then
        return false
    end

    if Rights.ObjectWhitelist and not Rights.ObjectWhitelist[ObjectType] then
        return false
    end

    if Rights.ObjectBlacklist[ObjectType] then
        return false
    end

    -- A destroy writes no property, so the property lists have nothing to say
    -- about one.
    if Property ~= nil and Action ~= "Destroy" then
        const Whitelist = Rights.PropertyWhitelist
        if Whitelist and not Listed(Whitelist, Property, ObjectType) then
            return false
        end

        if Listed(Rights.PropertyBlacklist, Property, ObjectType) then
            return false
        end
    end

    return true
end

--=============================================================================
-- The wire form
--=============================================================================

const function IdList(Set: {[number]: true}): {number}
    const List = {}
    for Id in Set do
        table.insert(List, Id)
    end

    table.sort(List)
    return List
end

const function PropertyList(Set: {[number]: Types.PropertyEntry}): {Types.PropertyEntryPayload}
    const List: {Types.PropertyEntryPayload} = {}
    for Property, Entry in Set do
        table.insert(List, {
            Property = Property,
            Types = if Entry == true then nil else IdList(Entry :: any),
        })
    end

    table.sort(List, function(A: Types.PropertyEntryPayload, B: Types.PropertyEntryPayload)
        return A.Property < B.Property
    end)

    return List
end

const function PropertyFromList(List: {Types.PropertyEntryPayload}?): {[number]: Types.PropertyEntry}
    const Set: {[number]: Types.PropertyEntry} = {}
    for _, Entry in List or {} do
        Set[Entry.Property] = if Entry.Types then IdSet(Entry.Types) else true
    end

    return Set
end

const function CapabilityList(Set: {[string]: true}): {string}
    const List = {}
    for Name in Set do
        table.insert(List, Name)
    end

    table.sort(List)
    return List
end

function Shared.EncodeScene(Rights: Types.SceneRights): Types.SceneRightsPayload
    return {
        Role = Rights.Role,
        CanCreate = Rights.CanCreate,
        CanEdit = Rights.CanEdit,
        CanDestroy = Rights.CanDestroy,
        ObjectWhitelist = if Rights.ObjectWhitelist then IdList(Rights.ObjectWhitelist) else nil,
        ObjectBlacklist = IdList(Rights.ObjectBlacklist),
        PropertyWhitelist = if Rights.PropertyWhitelist then PropertyList(Rights.PropertyWhitelist) else nil,
        PropertyBlacklist = PropertyList(Rights.PropertyBlacklist),
        Capabilities = CapabilityList(Rights.Capabilities),
    }
end

function Shared.DecodeScene(Payload: Types.SceneRightsPayload): Types.SceneRights
    return {
        Role = Payload.Role,
        CanCreate = Payload.CanCreate == true,
        CanEdit = Payload.CanEdit == true,
        CanDestroy = Payload.CanDestroy == true,
        ObjectWhitelist = if Payload.ObjectWhitelist then IdSet(Payload.ObjectWhitelist) else nil,
        ObjectBlacklist = IdSet(Payload.ObjectBlacklist),
        PropertyWhitelist = if Payload.PropertyWhitelist then PropertyFromList(Payload.PropertyWhitelist) else nil,
        PropertyBlacklist = PropertyFromList(Payload.PropertyBlacklist),
        Capabilities = CapabilitySet(Payload.Capabilities),
    }
end

function Shared.EncodeGlobal(Rights: Types.GlobalRights): Types.GlobalRightsPayload
    return {
        Role = Rights.Role,
        Rate = Rights.Rate,
        CanPush = Rights.CanPush,
        Capabilities = CapabilityList(Rights.Capabilities),
    }
end

function Shared.DecodeGlobal(Payload: Types.GlobalRightsPayload): Types.GlobalRights
    return {
        Role = Payload.Role,
        Rate = Payload.Rate or Shared.DEFAULT_RATE,
        CanPush = Payload.CanPush == true,
        Capabilities = CapabilitySet(Payload.Capabilities),
    }
end

return Shared
