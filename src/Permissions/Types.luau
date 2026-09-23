--!strict
-- Rights come in two kinds, and a role is written with both halves.
--
-- Global rights are about the session: the action budget, whether a client may
-- push a scene of its own, and capabilities that belong to no document. Scene
-- rights are about one scene: the three verbs, the object and property lists
-- they reach, and capabilities of that scene. Granting a role globally copies
-- its global half in; granting it on a scene copies its scene half.

export type Action = "Create" | "Edit" | "Destroy"

-- Registry ids. Plain numbers so this module does not have to depend on Objects
-- or Properties.
export type ObjectType = number
export type PropertyId = number

-- What a check is asked about. An object already carries both fields; a create
-- has no object yet, so it names the scene and the type it would make.
export type Target = {
    Scene: number,
    Registry: ObjectType,
}

-- A whitelist that is present is exhaustive, and one that is absent constrains
-- nothing -- the same thing the two words mean in enum constraints, and the
-- direction that fails closed when a list is built wrong.
export type ObjectLists = {
    Whitelist: {ObjectType}?,
    Blacklist: {ObjectType}?,
}

-- Property ids, as the object lists take object types, or [Property] =
-- {ObjectType} to limit an entry to those types. Kept apart from the object
-- lists so the field says which kind its keys are, and an id that is both a
-- property and an object type means one thing.
export type PropertyLists = {
    Whitelist: {[any]: any}?,
    Blacklist: {[any]: any}?,
}

export type SceneRoleConfig = {
    CanCreate: boolean?,
    CanEdit: boolean?,
    CanDestroy: boolean?,

    Objects: ObjectLists?,

    -- Writing only. Nothing in these is a reason to withhold data: what a
    -- client is sent is admission's business.
    Properties: PropertyLists?,

    -- Plain strings that exist by appearing here. Prism enforces its three
    -- verbs and only answers for these.
    Capabilities: {string}?,
}

export type GlobalRoleConfig = {
    -- Actions per second on the object remotes. A transaction spends one per
    -- operation it carries, so this bounds the work asked for rather than the
    -- number of times it is asked. Defaults to 60.
    Rate: number?,

    -- Whether a client may hand the server a scene it built.
    CanPush: boolean?,

    Capabilities: {string}?,
}

export type RoleConfig = {
    Global: GlobalRoleConfig?,
    Scene: SceneRoleConfig?,
}

-- One property's entry in a list: every type, or only these.
export type PropertyEntry = true | {[ObjectType]: true}

export type SceneRights = {
    -- The role most recently granted, for display. Informational only: the
    -- sets below are the whole truth, and a capability granted since may have
    -- moved them away from the role.
    Role: string?,

    CanCreate: boolean,
    CanEdit: boolean,
    CanDestroy: boolean,

    ObjectWhitelist: {[ObjectType]: true}?,
    ObjectBlacklist: {[ObjectType]: true},
    PropertyWhitelist: {[PropertyId]: PropertyEntry}?,
    PropertyBlacklist: {[PropertyId]: PropertyEntry},

    Capabilities: {[string]: true},
}

export type GlobalRights = {
    Role: string?,
    Rate: number,
    CanPush: boolean,
    Capabilities: {[string]: true},
}

export type Role = {
    Name: string,
    Global: GlobalRights,
    Scene: SceneRights,
}

-- What crosses the wire. Every set is a sequential array here: remotes do not
-- guarantee that non-sequential numeric keys survive serialization, and a map
-- sent as one used to arrive with entries missing, which made the client's Can
-- answer true for blacklisted types.
export type PropertyEntryPayload = {
    Property: PropertyId,
    Types: {ObjectType}?,
}

export type SceneRightsPayload = {
    Role: string?,
    CanCreate: boolean,
    CanEdit: boolean,
    CanDestroy: boolean,
    ObjectWhitelist: {ObjectType}?,
    ObjectBlacklist: {ObjectType},
    PropertyWhitelist: {PropertyEntryPayload}?,
    PropertyBlacklist: {PropertyEntryPayload},
    Capabilities: {string},
}

export type GlobalRightsPayload = {
    Role: string?,
    Rate: number,
    CanPush: boolean,
    Capabilities: {string},
}

return true
