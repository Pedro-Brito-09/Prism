--!strict
-- Permissions are named roles, not per object grants. A player holds exactly one
-- role; the role says which verbs it may use and which object types it may not
-- touch. That keeps the check O(1) and keeps authorization out of every object.

export type Action = "Create" | "Edit" | "Destroy"

-- Object registry id. Kept as a plain number so this module does not have to
-- depend on Objects.
export type ObjectType = number

export type PermissionConfig = {
    -- Ordering only. Prism never compares levels itself; it is there so your
    -- editor can ask "is this player at least a Builder" without a lookup table.
    Level: number,

    CanCreate: boolean?,
    CanEdit: boolean?,
    CanDestroy: boolean?,

    -- Actions per second this role may spend on the object remotes. Defaults to
    -- 60, which is roughly one action per frame. A transaction spends one per
    -- operation it carries rather than one for the packet, so this bounds the
    -- work asked for rather than the number of times it is asked.
    Rate: number?,

    -- Object types this role may never touch, whatever its verbs allow.
    Blacklist: {ObjectType}?,
}

export type Permission = {
    Name: string,
    Level: number,
    CanCreate: boolean,
    CanEdit: boolean,
    CanDestroy: boolean,
    Rate: number,
    Blacklist: {[ObjectType]: true},
}

-- What actually crosses the wire. Blacklist is a sequential array here rather
-- than the {[id]: true} map the server keeps: remotes do not guarantee that
-- non-sequential numeric keys survive serialization, so the map arrived on the
-- client with entries missing and Can() started answering true for blacklisted
-- types. The client rebuilds the map from this on arrival.
export type PermissionPayload = {
    Name: string,
    Level: number,
    CanCreate: boolean,
    CanEdit: boolean,
    CanDestroy: boolean,
    Rate: number,
    Blacklist: {ObjectType},
}

return true
