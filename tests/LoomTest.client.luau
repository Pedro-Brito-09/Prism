--!strict
--[[
    Loom test suite -- client half.

    Put this in StarterPlayerScripts, put Harness.luau at
    ReplicatedStorage/LoomTests/Harness, and run the server half alongside it.
    It verifies the things a server-only test cannot: that the ready handshake
    actually delivers, registries and live objects replicate, permissions
    update, and accepted/refused edits converge on the server's decision.

    It waits for the fixture the server script leaves behind, so run both.
]]

const ReplicatedStorage = game:GetService("ReplicatedStorage")

const LOOM = ReplicatedStorage:WaitForChild("Loom")
const CRATE_OBJECT = "TestCrate"
const BARE_OBJECT = "TestBare"
const FIXTURE_PROPERTY = "TestTitle"
const DENIED_MARKER = "FixtureDenied"
const EDITABLE_MARKER = "FixtureEditable"
const DESTROY_MARKER = "FixtureDestroy"
const TIMEOUT = 15

const Loom = require(LOOM)
const Harness = require(ReplicatedStorage:WaitForChild("LoomTests"):WaitForChild("Harness"))

const Permissions = Loom.Permissions
const Objects = Loom.Objects
const Properties = Loom.Properties

const T = Harness.new()

--=============================================================================
-- Wait for the handshake to deliver
--=============================================================================

const function FindProperty(Name: string): number?
    for Id, Registry in Properties:GetRegistered() do
        if Registry.Name == Name then
            return Id
        end
    end

    return nil
end

const function FindObjectType(Name: string): number?
    for Id, Registry in Objects:GetRegistered() do
        if Registry.Name == Name then
            return Id
        end
    end

    return nil
end

const function FindLiveObject(TypeId: number, PropertyId: number, Marker: string)
    for _, Obj in Objects:GetWorkspace() do
        if Obj.Parent == TypeId and Obj:Get(PropertyId) == Marker then
            return Obj
        end
    end

    return nil
end

const function WaitFor(What: string, Check: () -> any): any
    const Deadline = os.clock() + TIMEOUT

    while os.clock() < Deadline do
        const Result = Check()
        if Result then
            return Result
        end

        task.wait(0.1)
    end

    warn(`[ LOOM TEST ] Timed out waiting for {What}.`)
    return nil
end

print("[ LOOM TEST ] Waiting for replication...")

const TitleId = WaitFor("property registry", function()
    return FindProperty(FIXTURE_PROPERTY)
end)

const CrateId = WaitFor("crate registry", function()
    return FindObjectType(CRATE_OBJECT)
end)

const BareId = WaitFor("bare registry", function()
    return FindObjectType(BARE_OBJECT)
end)

const Denied = if CrateId and TitleId
    then WaitFor("denied fixture", function()
        return FindLiveObject(CrateId, TitleId, DENIED_MARKER)
    end)
    else nil

const Editable = if BareId and TitleId
    then WaitFor("editable fixture", function()
        return FindLiveObject(BareId, TitleId, EDITABLE_MARKER)
    end)
    else nil

const Destroyable = if BareId and TitleId
    then WaitFor("destroy fixture", function()
        return FindLiveObject(BareId, TitleId, DESTROY_MARKER)
    end)
    else nil

const Builder = WaitFor("TestBuilder permission", function()
    const Current = Permissions:Get()
    return if Current.Name == "TestBuilder" then Current else nil
end)

--=============================================================================
-- Replication
--=============================================================================

T:Describe("Replication")

T:Test("the ready handshake delivered the property registry", function()
    T:Ok(TitleId, "property arrived")

    if TitleId then
        const Registry = Properties:GetRegistry(TitleId)
        T:Eq(Registry.Name, FIXTURE_PROPERTY, "name")
        T:Eq(Registry.Type, "Text", "type")
        T:Eq(Registry.DefaultValue, "Untitled", "default value")
        T:Ok(Registry.Constraints, "constraints came across")
    end
end)

T:Test("the object registries arrived", function()
    T:Ok(CrateId, "object type arrived")
    T:Ok(BareId, "bare type arrived")

    if CrateId then
        const Registry = Objects:GetRegistry(CrateId)
        T:Eq(Registry.Name, CRATE_OBJECT, "crate name")
        T:Ok(#Registry.Properties > 0, "crate property list")
        T:Eq(Registry.Instance, nil, "crate template is not replicated")
    end

    if BareId then
        const Registry = Objects:GetRegistry(BareId)
        T:Eq(Registry.Name, BARE_OBJECT, "bare name")
        T:Ok(#Registry.Properties > 0, "bare property list")
    end
end)

T:Test("the live fixtures arrived with distinct values", function()
    T:Ok(Denied, "denied fixture arrived")
    T:Ok(Editable, "editable fixture arrived")
    T:Ok(Destroyable, "destroy fixture arrived")

    if Denied and TitleId then
        T:Eq(Denied:Get(TitleId), DENIED_MARKER, "value carried through the buffer")
        T:Eq(Denied:Get(FIXTURE_PROPERTY), DENIED_MARKER, "readable by name")
        T:Ok(not Denied.Destroyed, "alive")
        T:Ok(Denied.Properties[TitleId], "property instance rebuilt")
    end
end)

T:Test("the object's instance is reachable", function()
    if not Denied then
        T:Ok(false, "no instance-backed fixture")
        return
    end

    T:Ok(Denied.Instance, "instance came across")

    if Denied.Instance then
        T:Eq(Objects:FromInstance(Denied.Instance), Denied, "mapped back from the part")

        const Child = Instance.new("Part")
        Child.Parent = Denied.Instance
        T:Eq(Objects:FromInstance(Child), Denied, "mapped back from a descendant")
        Child:Destroy()
    end
end)

T:Test("an unrelated instance maps to nothing", function()
    const Stray = Instance.new("Part")
    Stray.Parent = workspace
    T:Eq(Objects:FromInstance(Stray), nil, "not an object")
    Stray:Destroy()
end)

--=============================================================================
-- Permissions
--=============================================================================

T:Describe("Permissions")

T:Test("the client received the builder role", function()
    const Current = Permissions:Get()
    T:Ok(Builder, "builder payload arrived")
    T:Eq(Current.Name, "TestBuilder", "role name")
    T:Ok(type(Current.Blacklist) == "table", "blacklist rebuilt as a map")
end)

T:Test("Can reflects verbs and the rebuilt blacklist", function()
    T:Ok(Permissions:Can("Create"), "builder can create")
    T:Ok(Permissions:Can("Edit"), "builder can edit")
    T:Ok(Permissions:Can("Destroy"), "builder can destroy")

    if CrateId and BareId then
        T:Ok(not Permissions:Can("Edit", CrateId), "crate is blacklisted")
        T:Ok(Permissions:Can("Edit", BareId), "bare type is allowed")
        T:Ok(Permissions:Get().Blacklist[CrateId], "blacklist entry is addressable by id")
    end
end)

T:Test("OnChange fires when the role changes", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    local SawViewer = false
    const Disconnect = Permissions:OnChange(function(Permission)
        if Permission.Name == "TestViewer" then
            SawViewer = true
        end
    end)

    T:Ok(type(Disconnect) == "function", "returns a disconnect")
    T:Ok(Editable:Set(TitleId, "PermissionPulse"), "pulse edit accepted locally")
    T:Eventually(function()
        return SawViewer
    end, 3, "viewer assignment observed")
    T:Eventually(function()
        return Permissions:Get().Name == "TestBuilder"
    end, 3, "builder assignment restored")
    Disconnect()
end)

--=============================================================================
-- Client edits
--=============================================================================

T:Describe("Client edits")

T:Test("a denied set applies optimistically, then rolls back", function()
    if not Denied or not TitleId then
        T:Ok(false, "no denied fixture")
        return
    end

    const Before = Denied:Get(TitleId)
    const Accepted = Denied:Set(TitleId, "ShouldBeReverted")

    T:Ok(Accepted, "accepted locally")
    T:Eq(Denied:Get(TitleId), "ShouldBeReverted", "applied without waiting")
    T:Eventually(function()
        return Denied:Get(TitleId) == Before
    end, 3, "server rejection rolled back")
end)

T:Test("an allowed set survives the server round trip", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    T:Ok(Editable:Set(TitleId, "ClientAccepted"), "accepted locally")
    T:Eq(Editable:Get(TitleId), "ClientAccepted", "applied immediately")

    -- A refused invoke rolls back asynchronously; surviving this interval also
    -- verifies the server accepted the edit and broadcast its authoritative value.
    task.wait(1)
    T:Eq(Editable:Get(TitleId), "ClientAccepted", "accepted value survived")
end)

T:Test("an invalid value is refused before it reaches the server", function()
    if not Editable then
        T:Ok(false, "no editable fixture")
        return
    end

    T:Ok(not Editable:Set(99999, "x"), "unknown property")
end)

T:Test("setting the same value twice is a no-op", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    const Current = Editable:Get(TitleId)
    T:Ok(Editable:Set(TitleId, Current), "accepted")
    T:Eq(Editable:Get(TitleId), Current, "unchanged")
end)

T:Test("an allowed destroy tears down the client object", function()
    if not Destroyable then
        T:Ok(false, "no destroy fixture")
        return
    end

    const RuntimeId = Destroyable.RuntimeId
    T:Ok(Destroyable:Destroy(), "server accepted destroy")
    T:Eventually(function()
        return Objects:Get(RuntimeId) == nil and Destroyable.Destroyed
    end, 3, "removal replicated")
    T:Eq(Destroyable:Get(FIXTURE_PROPERTY), nil, "stale getter is safe")
    T:Eq(Destroyable:Set(FIXTURE_PROPERTY, "x"), false, "stale setter is safe")
    T:Eq(Destroyable.Instance, nil, "instance reference released")
end)

--=============================================================================

if not T:Report() then
    error("[ LOOM TEST ] Client suite failed; see the failures above.", 0)
end
