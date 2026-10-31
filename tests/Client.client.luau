--!strict
--[[
    Prism test suite -- client half.

    Ships in PrismTests.rbxmx beside the server half, Harness and its own copy
    of Prism, and runs with RunContext Client from wherever the model sits.
    It verifies the things a server-only test cannot: that the ready handshake
    actually delivers, registries and live objects replicate, permissions
    update, and accepted/refused edits converge on the server's decision.

    It waits for the fixture the server script leaves behind, so run both.
]]

const ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Running from ReplicatedStorage, this can start before the rest of the model
-- has replicated, and Prism's requires resolve by child name.
if not game:IsLoaded() then
    game.Loaded:Wait()
end

const CRATE_OBJECT = "TestCrate"
const BARE_OBJECT = "TestBare"
const SHOWN_OBJECT = "TestShown"
const PRIVATE_OBJECT = "TestPrivate"
const FIXTURE_PROPERTY = "TestTitle"
const DENIED_MARKER = "FixtureDenied"
const EDITABLE_MARKER = "FixtureEditable"
const DESTROY_MARKER = "FixtureDestroy"
const EVICT_MARKER = "EvictPulse"
const UNREGISTER_MARKER = "UnregisterPulse"
const OPENED_MARKER = "OpenedPulse"
const TIMEOUT = 15

-- The live fixtures are made once the server's own suite has run, so waiting
-- for them is waiting for that suite. It outgrew TIMEOUT when the load tests
-- started building tens of thousands of objects.
const FIXTURE_TIMEOUT = 90

const Prism = require("./Prism")
const Harness = require("./Harness")

const Transactions = Prism.Transactions
const Permissions = Prism.Permissions
const Scenes = Prism.Scenes
const Objects = Prism.Objects
const Properties = Prism.Properties

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
        if Obj.Registry == TypeId and Obj:Get(PropertyId) == Marker then
            return Obj
        end
    end

    return nil
end

const function WaitFor(What: string, Check: () -> any, Timeout: number?): any
    const Deadline = os.clock() + (Timeout or TIMEOUT)

    while os.clock() < Deadline do
        const Result = Check()
        if Result then
            return Result
        end

        task.wait(0.1)
    end

    warn(`[ PRISM TEST ] Timed out waiting for {What}.`)
    return nil
end

print("[ PRISM TEST ] Waiting for replication...")

const TitleId = WaitFor("property registry", function()
    return FindProperty(FIXTURE_PROPERTY)
end)

const CrateId = WaitFor("crate registry", function()
    return FindObjectType(CRATE_OBJECT)
end)

const BareId = WaitFor("bare registry", function()
    return FindObjectType(BARE_OBJECT)
end)

const ShownId = WaitFor("shown registry", function()
    return FindObjectType(SHOWN_OBJECT)
end)

const PrivateId = WaitFor("private registry", function()
    return FindObjectType(PRIVATE_OBJECT)
end)

const Denied = if CrateId and TitleId
    then WaitFor("denied fixture", function()
        return FindLiveObject(CrateId, TitleId, DENIED_MARKER)
    end, FIXTURE_TIMEOUT)
    else nil

const Editable = if BareId and TitleId
    then WaitFor("editable fixture", function()
        return FindLiveObject(BareId, TitleId, EDITABLE_MARKER)
    end, FIXTURE_TIMEOUT)
    else nil

const Destroyable = if BareId and TitleId
    then WaitFor("destroy fixture", function()
        return FindLiveObject(BareId, TitleId, DESTROY_MARKER)
    end, FIXTURE_TIMEOUT)
    else nil

-- Rights on the default scene, where every editable fixture lives.
const Builder = if Editable
    then WaitFor("TestBuilder rights", function()
        const Rights = Permissions:GetOn(Editable.Scene)
        return if Rights and Rights.Role == "TestBuilder" then Rights else nil
    end, FIXTURE_TIMEOUT)
    else nil

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

T:Test("display metadata came across with the registry", function()
    const Speed = FindProperty("TestSpeed")
    const Spin = FindProperty("TestSpin")
    T:Ok(Speed and Spin, "the displayed properties arrived")

    if not Speed or not Spin then
        return
    end

    const Display = Properties:GetRegistry(Speed).Display
    T:Eq(Display.Category, "Motion", "category")
    T:Eq(Display.Description, "Studs a second", "description")

    const Layout = Properties:Layout({Speed, Spin})
    T:Eq(Layout[1].Properties[1].Id, Spin, "and the client lays it out the same way")
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
        T:Eq(Denied:GetProperty(FIXTURE_PROPERTY), Denied.Properties[TitleId], "name map built on the client too")
    end
end)

-- Run before this client edits anything. Every arriving property used to take
-- an entry here, and a Luau table keeps the room its emptied keys took: a
-- client held 16 MB of it after the real level was unloaded.
T:Test("an arriving object holds nothing for edits it has not had", function()
    local Count = 0
    for _, Obj in Objects:GetWorkspace() do
        for _ in Obj.Properties do
            Count += 1
        end
    end

    T:Ok(Count > 0, "properties arrived")
    T:Eq(Objects:CountConfirmed(), 0, "and none are held")
end)

T:Test("the object's instance is reachable", function()
    if not Denied then
        T:Ok(false, "no instance-backed fixture")
        return
    end

    -- Waited on rather than sampled. The object arrives over the remote and the
    -- part over ordinary replication, and when the reference sent beside the
    -- object does not survive the trip the link is rebuilt from the part's own
    -- tag, which lands whenever replication gets to it.
    T:Eventually(function()
        return Denied.Instance ~= nil
    end, 5, "instance came across")

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
-- Admission
--=============================================================================

T:Test("a custom enum registered here late still resolves", function()
    -- The server registers TestShapes, a property constrained to it, and an
    -- object holding Square. This client registers the enum only now, after
    -- all three arrived. It used to show the property's default until the
    -- server next changed it, because the value decoded to UNKNOWN and an
    -- unresolved constraint refused it.
    const ShapeId = FindProperty("TestShape")
    const ShapedType = FindObjectType("FixtureShapedType")
    T:Ok(ShapeId and ShapedType, "the property and type arrived")

    if not ShapeId or not ShapedType or not TitleId then
        return
    end

    const Shaped = T:Eventually(function()
        return FindLiveObject(ShapedType, TitleId, "FixtureShaped")
    end, 5, "the object arrived")

    if not Shaped then
        return
    end

    const Before = Shaped:Get(ShapeId)
    T:Ok(Before and Before.Pending, "held as a pending option, not the default")
    T:Eq(Before and Before.Id, 2, "with the server's option id")
    T:Eq(Before and Before.Value, nil, "and no Value yet")

    local Heard = nil
    const Stop = Shaped:OnChange(ShapeId, function(Value)
        Heard = Value
    end)

    const Shapes = Prism.CustomEnum:Register("TestShapes", {Circle = 1, Square = 2, Triangle = 3})
    T:Ok(Shapes, "registered here")

    if Shapes then
        T:Eventually(function()
            return Shaped:Get(ShapeId) == Shapes:GetById(2)
        end, 2, "the value became the real Square")

        T:Eq(Heard, Shapes:GetById(2), "and whoever was watching heard it")
        T:Eq(Properties:GetRegistry(ShapeId).Constraints.CustomEnum, Shapes, "the constraint resolved")
        T:Ok(not (Properties.new(ShapeId):Set(Prism.CustomEnum.Pending("TestShapesNot", 1))), "and an option of another enum is refused")
    end

    Stop()
end)

T:Describe("Admission")

T:Test("a scene arrives with the Guid it is saved under", function()
    const Scene = T:Eventually(function()
        return Scenes:Get("FixtureAdmitted")
    end, 5, "the scene arrived")

    if not Scene then
        return
    end

    T:Eq(type(Scene.Guid), "string", "a Guid")
    T:Eq(Scenes:GetByGuid(Scene.Guid), Scene, "found by it")
end)

T:Test("a scene you were not admitted to sends only what replicates to everyone", function()
    -- The admitted one first, so this does not pass merely because nothing has
    -- arrived yet.
    T:Eventually(function()
        return Scenes:Get("FixtureAdmitted")
    end, 5, "the scene beside it arrived")

    T:Eq(Scenes:Get("FixtureHidden"), nil, "not its name")

    if not BareId or not PrivateId or not TitleId then
        T:Ok(false, "no registries")
        return
    end

    const Scenery = T:Eventually(function()
        return FindLiveObject(BareId, TitleId, "FixtureHiddenScenery")
    end, 5, "its scenery")

    if Scenery then
        T:Eq(Scenes:GetInstanceScene(Scenery.InstanceId), Scenery.Scene, "filed under a copy it was told of")
        T:Eq(Scenes:GetById(Scenery.Scene), nil, "belonging to a scene it was not told the name of")
    end

    T:Eq(FindLiveObject(PrivateId, TitleId, "FixtureHiddenPrivate"), nil, "not what is kept for the admitted")
end)

T:Test("a private scene that admits nobody keeps everything but its scenery", function()
    if not BareId or not PrivateId or not ShownId or not TitleId then
        T:Ok(false, "no registries")
        return
    end

    const Scenery = T:Eventually(function()
        return FindLiveObject(BareId, TitleId, "FixtureClosedScenery")
    end, 5, "its scenery arrived, as every player is owed it")

    T:Eq(Scenes:Get("FixtureClosed"), nil, "not its name")
    T:Eq(FindLiveObject(PrivateId, TitleId, "FixtureClosedPrivate"), nil, "not what is kept for the admitted")
    T:Eq(FindLiveObject(ShownId, TitleId, "FixtureClosedOpened"), nil, "not its opened copy")

    if not Scenery then
        return
    end

    -- Rights on the scene, but not admitted to it: the server refuses the edit
    -- as though the object were not there, and the value comes back.
    task.wait(1.1)
    Scenery:Set(TitleId, "ClosedEdit")
    T:Eventually(function()
        return Scenery:Get(TitleId) == "FixtureClosedScenery"
    end, 3, "an edit to it was refused and rolled back")
end)

T:Test("a scene you were admitted to arrives whole", function()
    const Admitted = Scenes:Get("FixtureAdmitted")
    T:Ok(Admitted, "its registry")

    if not Admitted or not BareId or not PrivateId or not TitleId then
        return
    end

    T:Eq(#Scenes:GetInstances(Admitted.Id), 1, "its copy")

    T:Eventually(function()
        return FindLiveObject(BareId, TitleId, "FixtureAdmitScenery")
    end, 5, "its scenery")

    T:Eventually(function()
        return FindLiveObject(PrivateId, TitleId, "FixtureAdmitPrivate")
    end, 5, "and what is kept for the admitted")
end)

T:Test("eviction takes the name and what is kept for the admitted", function()
    const Admitted = Scenes:Get("FixtureAdmitted")
    const Scenery = if BareId and TitleId
        then FindLiveObject(BareId, TitleId, "FixtureAdmitScenery")
        else nil
    const Private = if PrivateId and TitleId
        then FindLiveObject(PrivateId, TitleId, "FixtureAdmitPrivate")
        else nil

    if not Admitted or not Scenery or not Private or not Editable or not TitleId then
        T:Ok(false, "no admitted fixture")
        return
    end

    -- The server evicts this player when the editable fixture carries the
    -- marker, the same way the permission pulse is asked for.
    Editable:Set(TitleId, EVICT_MARKER)

    T:Eventually(function()
        return Scenes:Get("FixtureAdmitted") == nil
    end, 5, "the name went")

    T:Eventually(function()
        return Private.Destroyed
    end, 5, "the private object went")

    T:Ok(not Scenery.Destroyed, "the scenery stayed, because every player is owed it")
    T:Eq(#Scenes:GetInstances(Admitted.Id), 1, "and so did its copy")

    Editable:Set(TitleId, EDITABLE_MARKER)
end)

--=============================================================================
-- Opened copies
--=============================================================================

T:Describe("Opened copies")

T:Test("an opened copy is drawn here, from the replicated template", function()
    if not ShownId or not TitleId then
        T:Ok(false, "no shown registry")
        return
    end

    const Obj = T:Eventually(function()
        return FindLiveObject(ShownId, TitleId, "FixtureOpenedObject")
    end, 5, "the object arrived")

    if not Obj then
        return
    end

    T:Ok(Obj.Drawn, "marked as drawn by this client")
    T:Ok(Obj.Instance, "with a part built here")

    if Obj.Instance then
        T:Eq(Obj.Instance.Parent, Scenes:GetFolder(Obj.InstanceId), "in the folder this client keeps for the copy")
        T:Eq(Obj.Instance:GetAttribute(FIXTURE_PROPERTY), "FixtureOpenedObject", "driven by the links that came with the registry")
        T:Eq(Objects:FromInstance(Obj.Instance), Obj, "and mapped back from the part")
    end
end)

T:Test("a loaded copy is the server's to draw", function()
    if not Editable then
        T:Ok(false, "no editable fixture")
        return
    end

    T:Eq(Scenes:GetFolder(Editable.InstanceId), nil, "so this client keeps no folder for it")
    T:Ok(not Editable.Drawn, "and drew nothing")
end)

T:Test("an object created in an opened copy reaches only the admitted", function()
    if not Editable or not ShownId or not BareId or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    -- The server creates the hidden object and then the control when the
    -- editable fixture carries the marker. Both go down the same remote, so by
    -- the time the control is here the hidden one would have been too.
    task.wait(1.1)
    Editable:Set(TitleId, OPENED_MARKER)

    T:Eventually(function()
        return FindLiveObject(BareId, TitleId, "FixtureOpenedControl")
    end, 5, "the control arrived")

    T:Eq(FindLiveObject(ShownId, TitleId, "FixtureOpenedLeak"), nil, "the object in a copy this player is not admitted to did not")
    T:Eq(Scenes:Get("FixtureOpenedHidden"), nil, "nor the scene's name")

    Editable:Set(TitleId, EDITABLE_MARKER)
end)

T:Test("watching copies hands back a disconnect", function()
    const Disconnect = Scenes:OnCopyAdded(function() end)
    T:Ok(type(Disconnect) == "function", "a function")
    Disconnect()
    Disconnect()
    T:Ok(true, "safe to call twice")
end)

--=============================================================================
-- Locks
--=============================================================================

T:Describe("Locks")

T:Test("a lock is taken, announced and released", function()
    if not Editable or not Builder then
        T:Ok(false, "no editable fixture")
        return
    end

    const Me = game:GetService("Players").LocalPlayer.UserId
    local HeardHeld = false
    local HeardFree = false

    const Stop = Objects:OnLockChanged(function(RuntimeId, UserId)
        if RuntimeId ~= Editable.RuntimeId then
            return
        end

        if UserId == Me then
            HeardHeld = true
        elseif UserId == nil then
            HeardFree = true
        end
    end)

    -- The builder's budget is five a second, and earlier tests spend it.
    task.wait(1.1)

    T:Ok(Objects:Lock(Editable), "locked")

    -- On the answer, not on the broadcast, which travels on the other remote
    -- and used to land after Lock had returned.
    T:Ok(Objects:IsLocked(Editable), "held the moment Lock returns")
    T:Eq(Objects:GetLock(Editable), Me, "by this player")

    T:Eventually(function()
        return Objects:GetLock(Editable) == Me and HeardHeld
    end, 3, "announced back as this player's")

    T:Ok(Objects:Unlock(Editable), "released")
    T:Ok(not Objects:IsLocked(Editable), "free the moment Unlock returns")

    T:Eventually(function()
        return Objects:GetLock(Editable) == nil and HeardFree
    end, 3, "announced free")

    Stop()
end)

T:Test("an object someone else holds refuses an edit on the spot", function()
    if not BareId or not TitleId then
        T:Ok(false, "no bare registry")
        return
    end

    const Held = T:Eventually(function()
        const Obj = FindLiveObject(BareId, TitleId, "FixtureHeld")
        return if Obj and Objects:IsLocked(Obj) then Obj else nil
    end, 5, "the held fixture arrived, held")

    if not Held then
        return
    end

    T:Eq(Objects:GetLock(Held), nil, "by something that is not a person")

    -- What a tool greys itself out by. It answered for rights alone, which this
    -- client has here, and stayed lit on an object nobody could touch.
    T:Ok(not Permissions:Can("Edit", Held, TitleId), "Can says no to an edit")
    T:Ok(not Permissions:Can("Destroy", Held), "and to a destroy")
    if Editable then
        T:Ok(Permissions:Can("Edit", Editable, TitleId), "while an object nobody holds is still editable")
    end

    T:Ok(not Held:Set(TitleId, "Grabbed"), "a set is refused")
    T:Eq(Held:Get(TitleId), "FixtureHeld", "and never shown")

    T:Ok(not Held:Set(TitleId, "Grabbed", true), "so is a preview")
    T:Eq(Held:Get(TitleId), "FixtureHeld", "which is not shown either")

    T:Ok(not Held:Destroy(), "and a destroy")
    T:Ok(not Held.Destroyed, "which left it where it was")
end)

T:Test("a transaction's holds are known the moment it returns", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    const Me = game:GetService("Players").LocalPlayer.UserId
    local Heard = 0

    const Stop = Objects:OnLockChanged(function(RuntimeId)
        if RuntimeId == Editable.RuntimeId then
            Heard += 1
        end
    end)

    task.wait(1.1)
    T:Ok(Transactions.new():Lock(Editable):Commit(), "locked through a transaction")
    T:Eq(Objects:GetLock(Editable), Me, "held by this player on return")

    -- The broadcast still comes, and says nothing new.
    task.wait(0.5)
    T:Eq(Heard, 1, "and heard once, not once from the answer and again from the broadcast")

    task.wait(1.1)
    T:Ok(Transactions.new():Set(Editable, TitleId, EDITABLE_MARKER):Unlock(Editable):Commit(), "released through a transaction")
    T:Ok(not Objects:IsLocked(Editable), "free on return")

    Stop()
end)

--=============================================================================
-- Unregistering
--=============================================================================

T:Describe("Unregistering")

T:Test("an unregistered type and property leave the client too", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    const Type = WaitFor("doomed type", function()
        return FindObjectType("FixtureDoomedType")
    end)

    T:Ok(Type, "the type arrived")
    T:Ok(FindProperty("FixtureDoomedProperty"), "and its property")

    -- The server drops both when the editable fixture carries the marker.
    T:Ok(Editable:Set(TitleId, UNREGISTER_MARKER), "asked the server to drop them")

    T:Eventually(function()
        return FindObjectType("FixtureDoomedType") == nil
    end, 5, "the type went")

    T:Eventually(function()
        return FindProperty("FixtureDoomedProperty") == nil
    end, 5, "and so did the property")

    Editable:Set(TitleId, EDITABLE_MARKER)
end)

--=============================================================================
-- Permissions
--=============================================================================

T:Describe("Permissions")

T:Test("the client received its global rights", function()
    const Global = Permissions:Get()
    T:Eq(Global.Role, "TestBuilder", "from the role granted")
    T:Eq(Global.Rate, 5, "its budget")
    T:Ok(Global.CanPush, "its right to push")
    T:Ok(Permissions:Has("TestPublish"), "and its global capability")
end)

T:Test("Can reflects the rights on the object's own scene", function()
    if not Builder or not Editable or not Denied or not BareId then
        T:Ok(false, "no builder rights on the fixtures")
        return
    end

    T:Ok(Permissions:Can("Edit", Editable), "may edit a bare object")
    T:Ok(Permissions:Can("Destroy", Editable), "and destroy one")
    T:Ok(Permissions:Can("Create", {Scene = Editable.Scene, Registry = BareId}), "and create one")
    T:Ok(not Permissions:Can("Edit", Denied), "but a crate is blacklisted")
    T:Ok(Permissions:Get().Capabilities, "capabilities rebuilt as a map")
    T:Ok(Permissions:Has("TestInvite", Editable.Scene), "and the scene's capability")

    -- A scene that has granted this player nothing: the admitted fixture was
    -- admitted, which is not the same thing.
    const Scenery = if TitleId then FindLiveObject(BareId, TitleId, "FixtureAdmitScenery") else nil
    if Scenery then
        T:Ok(not Permissions:Can("Edit", Scenery), "and nothing at all on a scene that granted nothing")
    end
end)

T:Test("OnChange fires when the rights on a scene change", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    const Scene = Editable.Scene
    local SawViewer = false
    const Disconnect = Permissions:OnChange(function(Changed)
        const Rights = if Changed == Scene then Permissions:GetOn(Scene) else nil
        if Rights and Rights.Role == "TestViewer" then
            SawViewer = true
        end
    end)

    T:Ok(type(Disconnect) == "function", "returns a disconnect")
    T:Ok(Editable:Set(TitleId, "PermissionPulse"), "pulse edit accepted locally")
    T:Eventually(function()
        return SawViewer
    end, 3, "viewer grant observed")
    T:Eventually(function()
        const Rights = Permissions:GetOn(Scene)
        return Rights ~= nil and Rights.Role == "TestBuilder"
    end, 3, "builder grant restored")
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

    -- TestBuilder allows 5 calls a second, and the tests just before this can
    -- spend them. A set past the budget is refused and rolls back, which reads
    -- as this test failing, so start a fresh window first.
    task.wait(1.1)

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

-- TestBuilder may spend five actions a second. Thirty frames of a drag sent one
-- by one would be refused from the sixth on; previewed, they cost the one set
-- that ends the drag.
T:Test("a ClientSided drag costs one action and lands where it ends", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    task.wait(1.1)

    const Start = Editable:Get(TitleId)
    local Edits = 0
    local From: any = nil
    const Disconnect = Objects:OnEdited(function(Obj, _, Before)
        if Obj == Editable then
            Edits += 1
            From = Before
        end
    end)

    for Frame = 1, 30 do
        T:Ok(Editable:Set(TitleId, `Drag{Frame}`, true), `frame {Frame} shown`)
    end

    T:Eq(Editable:Get(TitleId), "Drag30", "the preview is on screen")
    T:Eq(Edits, 0, "and nobody was told of an edit")

    -- The last frame's value again, which on screen changes nothing. It has to
    -- be sent anyway: the server has never heard of it.
    T:Ok(Editable:Set(TitleId, "Drag30"), "the drag ends")
    T:Eq(Edits, 1, "one edit")
    T:Eq(From, Start, "starting from before the drag")

    task.wait(1)
    T:Eq(Editable:Get(TitleId), "Drag30", "the server kept it")

    Disconnect()
end)

T:Test("a preview moves a part the server built, on this client", function()
    if not ShownId or not TitleId then
        T:Ok(false, "no shown registry")
        return
    end

    const Dragged = T:Eventually(function()
        const Obj = FindLiveObject(ShownId, TitleId, "FixtureDragged")
        return if Obj and Obj.Instance then Obj else nil
    end, 5, "the object and its part arrived")

    if not Dragged then
        return
    end

    T:Ok(not Dragged.Drawn and not Dragged.Local, "a part the server built")

    -- The link writes the part the moment the preview does. It used to wait
    -- for the server, which a preview never asks.
    T:Ok(Dragged:Set(TitleId, "DragPreview", true), "previewed")
    T:Eq(Dragged.Instance:GetAttribute(FIXTURE_PROPERTY), "DragPreview", "the part shows the preview")

    -- Let go where it started: nothing is sent, and the part goes back.
    T:Ok(Dragged:Set(TitleId, "FixtureDragged"), "cancelled")
    T:Eq(Dragged.Instance:GetAttribute(FIXTURE_PROPERTY), "FixtureDragged", "the part is back")
end)

T:Test("a drag let go where it started sends and records nothing", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    const Start = Editable:Get(TitleId)
    local Edits = 0
    const Disconnect = Objects:OnEdited(function(Obj)
        if Obj == Editable then
            Edits += 1
        end
    end)

    Editable:Set(TitleId, "Wandered", true)
    T:Ok(Editable:Set(TitleId, Start), "cancelled")
    T:Eq(Editable:Get(TitleId), Start, "back where it was")
    T:Eq(Edits, 0, "and no edit was made")

    Disconnect()
end)

T:Test("a refused drag rolls back to before it began", function()
    if not Denied or not TitleId then
        T:Ok(false, "no denied fixture")
        return
    end

    task.wait(1.1)

    const Start = Denied:Get(TitleId)
    for Frame = 1, 10 do
        Denied:Set(TitleId, `Refused{Frame}`, true)
    end

    -- Nothing was sent, so nothing was refused yet: a preview is not judged.
    task.wait(0.5)
    T:Eq(Denied:Get(TitleId), "Refused10", "the preview stands until it ends")

    T:Ok(Denied:Set(TitleId, "Refused10"), "accepted locally")
    T:Eventually(function()
        return Denied:Get(TitleId) == Start
    end, 3, "rolled back to the value before the drag")
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
    T:Eq(Destroyable:GetProperty(FIXTURE_PROPERTY), nil, "stale lookup is safe")
    T:Eq(typeof(Destroyable:OnChange(FIXTURE_PROPERTY, function() end)), "function", "stale watch answers a disconnect")
    T:Eq(Destroyable.Instance, nil, "instance reference released")
end)

--=============================================================================
-- Client transactions
--=============================================================================

T:Describe("Client transactions")

-- TestBuilder's budget is five operations a second and a transaction spends one
-- per operation, so every test that sends one opens a fresh window first.
const function Window()
    task.wait(1.1)
end

local CreatedId: number? = nil

T:Test("a client creates an object, which it cannot do any other way", function()
    if not BareId or not TitleId then
        T:Ok(false, "no bare registry")
        return
    end

    Window()

    const Applied, Created = Transactions.new()
        :Create(BareId, {[TitleId] = "FromClient"})
        :Commit()

    T:Ok(Applied, "the server applied it")
    T:Eq(#Created, 1, "one runtime id came back")

    CreatedId = Created[1]

    const Made = T:Eventually(function()
        return Objects:Get(Created[1])
    end, 5, "the created object replicated back")

    if Made then
        T:Eq(Made:Get(TitleId), "FromClient", "with the value the create carried")
        T:Eq(Made.Registry, BareId, "of the type the create named")
    end
end)

T:Test("a blacklisted type is refused", function()
    if not CrateId then
        T:Ok(false, "no crate registry")
        return
    end

    Window()

    const Applied = Transactions.new():Create(CrateId, {}):Commit()
    T:Ok(not Applied, "refused")
end)

T:Test("a copy that is not live is refused", function()
    if not BareId then
        T:Ok(false, "no bare registry")
        return
    end

    Window()

    const Applied = Transactions.new():Create(BareId, {}, 999999):Commit()
    T:Ok(not Applied, "refused")
end)

T:Test("a set and a destroy land as one edit", function()
    const Made = if CreatedId then Objects:Get(CreatedId) else nil
    if not Made or not TitleId then
        T:Ok(false, "nothing to edit")
        return
    end

    Window()

    const Applied = Transactions.new()
        :Set(Made, TitleId, "EditedThenGone")
        :Destroy(Made)
        :Commit()

    T:Ok(Applied, "applied")
    T:Eventually(function()
        return Objects:Get(CreatedId :: number) == nil and Made.Destroyed
    end, 5, "the removal replicated")
end)

T:Test("an operation that cannot be built never reaches the server", function()
    if not Editable then
        T:Ok(false, "no editable fixture")
        return
    end

    const Edit = Transactions.new():Set(Editable, "NoSuchProperty", "x")

    T:Eq(Edit.Rejected, 1, "refused while building")
    T:Eq(#Edit.Operations, 0, "nothing to send")
    T:Ok(not Edit:Commit(), "commit refused")
end)

T:Test("duplicating a server object builds a create into its copy", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    -- Built, not committed: what goes on the wire is the whole of it.
    const Edit = Transactions.new():Duplicate(Editable)
    const Operation = Edit.Operations[1] :: any

    T:Eq(Edit.Rejected, 0, "built")
    T:Eq(Operation.Kind, "Create", "as a create")
    T:Eq(Operation.Object, Editable.Registry, "of the same type")
    T:Eq(Operation.Instance, Editable.InstanceId, "into its copy")
    T:Eq(Operation.Properties[TitleId], Editable:Get(TitleId), "holding its value")
end)

T:Test("committing nothing succeeds without a round trip", function()
    const Applied, Created = Transactions.new():Commit()
    T:Ok(Applied, "succeeded")
    T:Eq(#Created, 0, "created nothing")
end)

--=============================================================================
-- Scenes this client owns
--=============================================================================

T:Describe("Local scenes")

-- A registry arrives carrying its template and links, and a local object
-- clones, tags and drives that template exactly as a server side object does.
-- Only a template this client can see arrives as anything: TestShown's sits in
-- ReplicatedStorage, TestCrate's in ServerStorage.
const ShownTemplate = ReplicatedStorage:WaitForChild("PrismShownTemplate", TIMEOUT)

T:Test("a registry arrives with its template and links", function()
    const Shown = if ShownId then Objects:GetRegistry(ShownId) else nil
    const Crate = if CrateId then Objects:GetRegistry(CrateId) else nil

    if not Shown or not Crate then
        T:Ok(false, "no registries")
        return
    end

    T:Ok(ShownTemplate, "the template replicated")
    T:Eq(Shown.Instance, ShownTemplate, "and the registry names it")
    T:Ok(Shown.Links and #Shown.Links == 1, "its link came with it")

    T:Eq(Crate.Instance, nil, "a template in ServerStorage arrives as nil")
    T:Ok(Crate.HasTemplate, "while the registry says there is one")
    T:Ok(Crate.Links and #Crate.Links == 2, "its links still arrive, and drive nothing without it")
end)

T:Test("a local scene loads a copy and builds objects in it", function()
    const Sandbox = Scenes.new({Name = "ClientSandbox"})
    T:Ok(Sandbox, "registered")

    if not Sandbox then
        return
    end

    T:Eq(Scenes:GetLocal("ClientSandbox"), Sandbox, "reachable by name")
    T:Eq(Scenes.new({Name = "ClientSandbox"}), nil, "a second scene cannot take the name")

    const Copy = Sandbox:Load()
    T:Ok(Copy, "loaded a copy")

    const Obj = Copy:Create(ShownId, {[TitleId] = "Local"})
    T:Ok(Obj, "created")
    T:Ok(Obj.Local, "marked as this client's own")
    T:Eq(Obj:Get(TitleId), "Local", "initial value applied")
    T:Eq(Obj.LocalId, 1, "first local id")
    T:Eq(Obj.Scene, Sandbox.Id, "stamped with its scene")
    T:Eq(Copy:Find(1), Obj, "the copy answers for it")
    T:Eq(Objects:Get(Obj.RuntimeId), Obj, "and so does the workspace")

    -- Local runtime ids count down from the top; the server's count up from
    -- one, and this client is holding both kinds at once.
    T:Ok(Obj.RuntimeId > 4000000000, "runtime id came from the local end of the space")

    T:Ok(Obj.Instance, "cloned the template it was handed")

    if Obj.Instance then
        T:Eq(Obj.Instance.Parent, Copy.Folder, "parented into the copy's folder")
        T:Ok(Obj.Instance ~= ShownTemplate, "not the template itself")
        T:Eq(Obj.Instance:GetAttribute(FIXTURE_PROPERTY), "Local", "the link drove the attribute")
        T:Eq(Objects:FromInstance(Obj.Instance), Obj, "and maps back from the part")
    end

    Sandbox:Destroy()
end)

T:Test("an edit applies on the spot and nothing takes it back", function()
    const Sandbox = Scenes.new({Name = "ClientEdits"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Obj = Copy:Create(ShownId, {[TitleId] = "Before"})

    T:Ok(Obj:Set(TitleId, "After"), "accepted")
    T:Eq(Obj:Get(TitleId), "After", "applied immediately")

    if Obj.Instance then
        T:Eq(Obj.Instance:GetAttribute(FIXTURE_PROPERTY), "After", "the link followed it")
    end

    -- A refused set on a replicated object rolls back within a round trip.
    -- There is no round trip here, and this is what that means.
    task.wait(1)
    T:Eq(Obj:Get(TitleId), "After", "still what it was set to")

    T:Ok(not Obj:Set(99999, "x"), "an unknown property is still refused")

    Sandbox:Destroy()
end)

T:Test("a copy serialises and reads back under the same ids", function()
    const Sandbox = Scenes.new({Name = "ClientRoundTrip"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const First = Copy:Create(BareId, {[TitleId] = "One"})
    const Second = Copy:Create(BareId, {[TitleId] = "Two"})
    const Persistent = Second.PersistentId

    Copy:Commit()
    Copy:Unload()

    T:Eq(Objects:Get(First.RuntimeId), nil, "unloading took its objects")
    T:Ok(First.Destroyed, "and tore them down")

    const Reloaded = Sandbox:Load()
    const Back = Reloaded:Find(2)

    T:Ok(Back, "the second object came back")

    if Back then
        T:Eq(Back:Get(TitleId), "Two", "with its value")
        T:Eq(Back.PersistentId, Persistent, "under the identity it was saved with")
        T:Ok(Back.RuntimeId ~= Second.RuntimeId, "but a new live identity")
    end

    -- The counter rode along in the pack, so a fresh object cannot answer to a
    -- name one of the restored ones already holds.
    T:Eq(Reloaded:Create(BareId).LocalId, 3, "the counter continued")

    Sandbox:Destroy()
end)

-- A level written by a build that had a type and a property this one does not.
T:Test("what this build cannot read survives a local save", function()
    const Compressor = Prism.Compressor
    const Foreign = Compressor:CompressScene(2, {
        {
            __type = "DecompressedObject",
            LocalId = 1,
            Registry = BareId,
            Properties = {[TitleId] = "Known"},
            Unknown = {[99991] = Compressor:CompressValue("Text", "FromElsewhere")},
        },
        {
            __type = "DecompressedObject",
            LocalId = 2,
            Registry = 99990,
            Properties = {[TitleId] = "Stranger"},
        },
    } :: any)

    const Sandbox = Scenes.fromBuffer({Name = "ClientForeign"}, Foreign)
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    T:Eq(#Copy:GetObjects(), 1, "only the known object was built")
    T:Eq(#Copy.Unknown, 1, "the other was kept")

    const Obj = Copy:Find(1)
    T:Ok(Obj and Obj.Unknown and Obj.Unknown[99991], "and so was the unreadable value")

    Copy:Commit()

    const _, Back = Compressor:DecompressScene(Sandbox:Serialize())
    T:Eq(#Back, 2, "both objects are still in the pack")
    T:Eq(Back[2] and Back[2].Registry, 99990, "the unknown one under its own type")
    T:Ok(Back[1] and Back[1].Unknown and Back[1].Unknown[99991], "the unreadable value too")

    Sandbox:Destroy()
end)

T:Test("loading twice gives two copies that do not touch each other", function()
    const Sandbox = Scenes.new({Name = "ClientTwice"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    Copy:Create(BareId, {[TitleId] = "Original"})
    Copy:Commit()
    Copy:Unload()

    const A = Sandbox:Load()
    const B = Sandbox:Load()

    T:Ok(A.Id ~= B.Id, "two copies")
    T:Ok(A:Find(1) ~= B:Find(1), "each holds its own object")
    T:Eq(A:Find(1).PersistentId, B:Find(1).PersistentId, "agreeing on what it is")
    T:Eq(#Sandbox:GetInstances(), 2, "the scene knows about both")

    A:Unload()
    T:Ok(B:Find(1) and not B:Find(1).Destroyed, "unloading one leaves the other alone")

    Sandbox:Destroy()
    T:Eq(Scenes:GetLocal("ClientTwice"), nil, "destroying takes the scene with it")
end)

T:Test("destroying a local object takes its part with it", function()
    const Sandbox = Scenes.new({Name = "ClientDestroy"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Obj = Copy:Create(ShownId)
    const Part = Obj.Instance

    T:Ok(Part, "built with a part")
    T:Ok(Obj:Destroy(), "destroyed")
    T:Ok(Obj.Destroyed, "marked")
    T:Eq(Objects:Get(Obj.RuntimeId), nil, "out of the workspace")
    T:Eq(Copy:Find(Obj.LocalId), nil, "out of the copy")

    if Part then
        T:Eq(Part.Parent, nil, "the part it owned went with it")
    end

    Sandbox:Destroy()
end)

T:Test("a local object duplicates into its own copy", function()
    const Sandbox = Scenes.new({Name = "ClientDuplicate"})
    if not Sandbox or not ShownId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Original = Copy:Create(ShownId, {[TitleId] = "Original"})
    const Twin = Objects:Duplicate(Original)

    T:Ok(Twin and Twin.Local, "a local object")

    if Twin then
        T:Eq(Twin:Get(TitleId), "Original", "holding the original's value")
        T:Eq(Copy:Find(Twin.LocalId), Twin, "filed in the same copy")
        T:Ok(Twin.Instance and Twin.Instance ~= Original.Instance, "with a part of its own")
    end

    if Editable then
        T:Eq(Objects:Duplicate(Editable), nil, "a server object is a transaction's to duplicate")
    end

    Sandbox:Destroy()
end)

T:Test("objects appearing and going are announced", function()
    const Sandbox = Scenes.new({Name = "ClientSignals"})
    if not Sandbox or not BareId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    local Added: any = nil
    local Removed: any = nil

    const StopAdded = Objects:OnAdded(function(Obj)
        Added = Obj
    end)

    const StopRemoved = Objects:OnRemoved(function(Obj)
        Removed = Obj
    end)

    const Obj = Copy:Create(BareId)
    T:Eventually(function()
        return Added == Obj
    end, 2, "added fired with the object")
    T:Eq(Objects:Get(Obj.RuntimeId), Obj, "already filed when told")

    Obj:Destroy()
    T:Eventually(function()
        return Removed == Obj
    end, 2, "removed fired with it")
    T:Ok(Removed and Removed.Destroyed, "already torn down when told")

    StopAdded()
    StopRemoved()
    StopAdded()

    const Later = Copy:Create(BareId)
    task.wait(0.2)
    T:Ok(Added ~= Later, "a disconnected listener hears nothing more")

    Sandbox:Destroy()
end)

T:Test("creating without a copy of your own is refused", function()
    T:Throws(function()
        Objects.new(BareId, nil, nil)
    end, "no local copy named")
end)

T:Test("a local scene is handed to the server as a pack", function()
    const Sandbox = Scenes.new({Name = "ClientPush"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    Copy:Create(BareId, {[TitleId] = "Handed over"})
    Copy:Commit()

    Window()

    const Accepted, Identifier, Reason = Sandbox:Push("ClientPushedRoom")
    T:Ok(Accepted, "the server took it")
    T:Eq(Reason, nil, "with no reason to give")
    T:Ok(Identifier and Identifier > 0, "and answered with its id")

    -- It registers on the server admitting only its author, which is this
    -- client, so its registry comes back here and nowhere else.
    T:Eventually(function()
        return Scenes:Get("ClientPushedRoom")
    end, 5, "the scene came back as one of the server's")

    T:Eventually(function()
        const Pushed = Scenes:Get("ClientPushedRoom")
        const Rights = if Pushed then Permissions:GetOn(Pushed.Id) else nil
        return Rights ~= nil and Rights.Role == "TestBuilder"
    end, 5, "and this client holds the push role on it")

    T:Ok(Scenes:GetLocal("ClientPush"), "and the local one is still local")
    T:Ok(Copy:Find(1), "still holding its own objects")

    Sandbox:Destroy()
end)

T:Test("a refused push says why", function()
    const Sandbox = Scenes.new({Name = "ClientPushRefused"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    Copy:Create(BareId, {[TitleId] = "Again"})
    Copy:Commit()

    -- The name the test above already took. It used to answer false and
    -- nothing else, whatever the rule it broke.
    Window()
    const Taken, _, Why = Sandbox:Push("ClientPushedRoom")
    T:Ok(not Taken, "refused")
    T:Eq(Why, "NameTaken", "because the name is taken")

    Window()
    const Blank, _, Empty = Sandbox:Push("")
    T:Ok(not Blank, "refused")
    T:Eq(Empty, "BadName", "because a scene needs a name")

    Sandbox:Destroy()
end)

--=============================================================================

--=============================================================================
-- References
--=============================================================================

T:Describe("References")

const DoorId = FindObjectType("TestDoor")
const ButtonId = FindObjectType("TestButton")
const TargetId = FindProperty("TestTarget")
const DoorOnlyId = FindProperty("TestDoorOnly")

T:Test("a replicated reference resolves to the object it names", function()
    if not DoorId or not ButtonId or not TargetId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Door = WaitFor("reference door", function()
        return FindLiveObject(DoorId :: number, TitleId :: number, "FixtureReferenceDoor")
    end)

    const Button = WaitFor("reference button", function()
        return FindLiveObject(ButtonId :: number, TitleId :: number, "FixtureRefButton")
    end)

    if not Door or not Button then
        T:Ok(false, "fixtures never arrived")
        return
    end

    -- The id came across as a plain number inside the object, and this side
    -- resolved it through its own index of the same copy.
    T:Eq(Button:GetProperty(TargetId).Value, Door.LocalId, "the id came across")
    T:Eq(Button:Get(TargetId), Door, "and reads back as the door")
    T:Eq(Door.InstanceId, Button.InstanceId, "both in the copy the server put them in")
end)

T:Test("a copy's origin reaches the client", function()
    const SpaceBlockId = FindObjectType("TestSpaceBlock")
    const SpaceSpotId = FindProperty("TestSpaceSpot")
    if not SpaceBlockId or not SpaceSpotId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Block = WaitFor("moved block", function()
        return FindLiveObject(SpaceBlockId :: number, TitleId :: number, "FixtureMovedBlock")
    end)

    if not Block then
        T:Ok(false, "fixture never arrived")
        return
    end

    T:Eq(Block:Get(SpaceSpotId), CFrame.new(1, 0, 0), "the value is relative to the copy")
    T:Eq(Scenes:GetOrigin(Block.InstanceId), CFrame.new(1000, 0, 0), "the origin arrived")
    T:Eq(Scenes:ToWorld(Block.InstanceId, Block:Get(SpaceSpotId)), CFrame.new(1001, 0, 0), "and converts")

    -- What this client writes itself lands where the server's part does.
    T:Ok(Block:Set(SpaceSpotId, CFrame.new(2, 0, 0), true), "a preview")
    if Block.Instance then
        T:Eq(Block.Instance.CFrame, CFrame.new(1002, 0, 0), "lands in the world")
    end

    Block:Set(SpaceSpotId, CFrame.new(1, 0, 0), true)
end)

T:Test("a copy this client owns has a local space", function()
    const SpaceBlockId = FindObjectType("TestSpaceBlock")
    const SpaceSpotId = FindProperty("TestSpaceSpot")
    const Sandbox = Scenes.new({Name = "ClientSpace"})
    if not SpaceBlockId or not SpaceSpotId or not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load(nil, {Origin = CFrame.new(500, 0, 0)})
    const Block = Copy:Create(SpaceBlockId, {[SpaceSpotId] = CFrame.new(1, 0, 0)})

    T:Eq(Block.Instance.CFrame, CFrame.new(501, 0, 0), "the part lands in the world")
    T:Ok(Copy:SetOrigin(CFrame.new(700, 0, 0)), "moved")
    T:Eq(Block.Instance.CFrame, CFrame.new(701, 0, 0), "and it went with the copy")
    T:Eq(Block:Get(SpaceSpotId), CFrame.new(1, 0, 0), "while the value stayed")

    Sandbox:Destroy()
end)

T:Test("an address through an insert resolves here as it does there", function()
    if not ButtonId or not TargetId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Button = WaitFor("room button", function()
        return FindLiveObject(ButtonId :: number, TitleId :: number, "FixtureRoomButton")
    end)

    if not Button then
        T:Ok(false, "fixture never arrived")
        return
    end

    const Door = WaitFor("the door in the far hallway", function()
        return Button:Get(TargetId)
    end)

    T:Ok(Door, "it names a door here")
    if Door then
        T:Eq(Door:Get(TitleId), "FixtureHallDoor", "the hallway's")
        T:Eq(Scenes:GetOrigin(Door.InstanceId), CFrame.new(2000, 0, 0), "in the far one of the two")
    end
end)

T:Test("a replicated address resolves through the scene it names", function()
    if not DoorId or not ButtonId or not TargetId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Door = WaitFor("remote door", function()
        return FindLiveObject(DoorId :: number, TitleId :: number, "FixtureRemoteDoor")
    end)

    const Button = WaitFor("remote button", function()
        return FindLiveObject(ButtonId :: number, TitleId :: number, "FixtureRemoteButton")
    end)

    if not Door or not Button then
        T:Ok(false, "fixtures never arrived")
        return
    end

    T:Eq(type(Button:GetProperty(TargetId).Value), "string", "the address came across")
    T:Eq(Button:Get(TargetId), Door, "and reads back as the door, in another scene")
end)

T:Test("an address into a scene this player cannot see reads as nothing", function()
    if not ButtonId or not TargetId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Button = WaitFor("hidden button", function()
        return FindLiveObject(ButtonId :: number, TitleId :: number, "FixtureHiddenButton")
    end)

    if not Button then
        T:Ok(false, "fixture never arrived")
        return
    end

    T:Eq(type(Button:GetProperty(TargetId).Value), "string", "the address is held")
    T:Eq(Button:Get(TargetId), nil, "and names nothing here")
end)

T:Test("a scene this client owns cannot be pointed at from another", function()
    if not DoorId or not ButtonId or not TargetId then
        T:Ok(false, "not registered")
        return
    end

    const Here = Scenes.new({Name = "ClientCrossHere"})
    const There = Scenes.new({Name = "ClientCrossThere"})
    if not Here or not There then
        T:Ok(false, "not registered")
        return
    end

    const Door = There:Load():Create(DoorId)
    const Button = Here:Load():Create(ButtonId)

    T:Ok(not Button:Set(TargetId, Door), "refused: it has no Guid to be named by")
    T:Eq(Button:GetProperty(TargetId).Value, 0, "and it still points at nothing")

    Here:Destroy()
    There:Destroy()
end)

T:Test("a reference in a local scene behaves as it does on the server", function()
    if not DoorId or not ButtonId or not TargetId or not DoorOnlyId then
        T:Ok(false, "not registered")
        return
    end

    const Sandbox = Scenes.new({Name = "ClientReferences"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId, {[TitleId] = "Button"})

    T:Ok(Button:Set(TargetId, Door), "takes the object")
    T:Eq(Button:Get(TargetId), Door, "and hands it back")
    T:Eq(Button:GetProperty(TargetId).Value, Door.LocalId, "storing the local id")

    T:Ok(not Button:Set(DoorOnlyId, Button), "a constrained reference refuses the wrong type")
    T:Ok(Button:Set(DoorOnlyId, Door), "and takes the right one")

    Door:Destroy()
    T:Eq(Button:Get(TargetId), nil, "a destroyed target reads as nothing")
    T:Ok(Button:GetProperty(TargetId).Value ~= 0, "while the id stays")

    Sandbox:Destroy()
end)

T:Test("a reference survives a local commit and reload", function()
    if not DoorId or not ButtonId or not TargetId then
        T:Ok(false, "not registered")
        return
    end

    const Sandbox = Scenes.new({Name = "ClientReferencesSaved"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId, {[TitleId] = "Button"})
    Button:Set(TargetId, Door)

    Copy:Commit()
    Copy:Unload()

    const Reloaded = Sandbox:Load()
    const Back = Reloaded:Find(Button.LocalId)

    T:Ok(Back, "the button came back")

    if Back then
        T:Eq(Back:Get(TargetId), Reloaded:Find(Door.LocalId), "still pointing at the door")
    end

    Sandbox:Destroy()
end)

T:Test("a group duplicate remaps what points inside it", function()
    if not DoorId or not ButtonId or not TargetId then
        T:Ok(false, "not registered")
        return
    end

    const Sandbox = Scenes.new({Name = "ClientReferencesGroup"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId, {[TitleId] = "Button"})
    Button:Set(TargetId, Door)

    const Alone = Objects:Duplicate(Button)
    T:Eq(Alone:Get(TargetId), Door, "one on its own keeps the original target")

    const Made = Objects:DuplicateGroup({Button, Door})
    T:Eq(#Made, 2, "both were made")

    if #Made == 2 then
        T:Eq(Made[1]:Get(TargetId), Made[2], "and the copy points at the copy")
        T:Eq(Button:Get(TargetId), Door, "the original is untouched")
    end

    Sandbox:Destroy()
end)

--=============================================================================
-- History
--=============================================================================

T:Describe("History")

const History = Prism.History

T:Test("a ClientSided drag is one step however long it pauses", function()
    const Sandbox = Scenes.new({Name = "ClientHistoryDrag"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Obj = Copy:Create(BareId, {[TitleId] = "Start"})
    History:Clear()

    -- Longer than the merge window: sent as plain sets, this would be two.
    Obj:Set(TitleId, "Held", true)
    T:Ok(not History:CanUndo(), "a preview records nothing")
    task.wait(1.2)
    Obj:Set(TitleId, "Released", true)
    Obj:Set(TitleId, "Released")

    T:Ok(History:Undo(), "undone")
    T:Eq(Obj:Get(TitleId), "Start", "back to before the drag")
    T:Ok(not History:CanUndo(), "which was one step")

    -- Let go where it began: no step at all.
    History:Clear()
    Obj:Set(TitleId, "Elsewhere", true)
    Obj:Set(TitleId, "Start")
    T:Ok(not History:CanUndo(), "a cancelled drag is not an action")

    History:Clear()
    Sandbox:Destroy()
end)

T:Test("this client's own steps are capped by what they hold", function()
    const Sandbox = Scenes.new({Name = "ClientHistoryWeight"})
    if not Sandbox or not BareId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Limits = History:GetLimits()
    History:Clear()
    History:SetLimits({Objects = 2})

    -- Three creates, one object held each once undone or kept.
    const Made = {}
    for Index = 1, 3 do
        Made[Index] = Copy:Create(BareId)
    end

    T:Ok(History:Undo(), "one")
    T:Ok(History:Undo(), "two")
    T:Ok(not History:CanUndo(), "and the oldest create was let go")
    T:Ok(not Made[1].Destroyed, "which leaves its object where it was")

    History:SetLimits(Limits)
    History:Clear()
    Sandbox:Destroy()
end)

T:Test("a run of sets in a local scene is one step", function()
    const Sandbox = Scenes.new({Name = "ClientHistory"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Obj = Copy:Create(BareId, {[TitleId] = "Start"})

    -- Creating is a step of its own now, and this test is about the sets.
    History:Clear()

    -- Two sets back to back are one drag.
    Obj:Set(TitleId, "A")
    Obj:Set(TitleId, "B")
    T:Ok(History:CanUndo(), "recorded")

    T:Ok(History:Undo(), "undone")
    T:Eq(Obj:Get(TitleId), "Start", "back to before the run")
    T:Ok(not History:CanUndo(), "which was one step")

    T:Ok(History:Redo(), "redone")
    T:Eq(Obj:Get(TitleId), "B", "forward to where the run ended")

    -- A pause ends the run.
    task.wait(1.1)
    Obj:Set(TitleId, "C")
    T:Ok(History:Undo(), "the later edit undone on its own")
    T:Eq(Obj:Get(TitleId), "B", "leaving the run in place")

    -- A change from elsewhere since is left alone. Setting the property itself
    -- goes around Object:Set, the way a change arriving from the server does.
    T:Ok(History:Redo(), "redone again")
    Obj.Properties[TitleId]:Set("Theirs")
    T:Ok(History:Undo(), "the undo still goes through")
    T:Eq(Obj:Get(TitleId), "Theirs", "without writing over it")

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("a create in a local scene undoes as the same object", function()
    const Sandbox = Scenes.new({Name = "ClientHistoryCreate"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    History:Clear()

    const Copy = Sandbox:Load()
    const Obj = Copy:Create(BareId, {[TitleId] = "Placed"})
    const RuntimeId = Obj.RuntimeId
    const LocalId = Obj.LocalId

    T:Ok(History:CanUndo(), "creating was recorded")

    T:Ok(History:Undo(), "undone")
    T:Ok(Obj.Suspended, "the object is held rather than ended")
    T:Eq(Copy:Find(LocalId), nil, "and gone from the copy")

    T:Ok(History:Redo(), "redone")

    -- The same table, under the same ids: the whole reason a create is undone
    -- by withdrawing rather than destroying.
    T:Eq(Objects:Get(RuntimeId), Obj, "back as itself")
    T:Eq(Copy:Find(LocalId), Obj, "under its own local id")
    T:Eq(Obj:Get(TitleId), "Placed", "still holding what it held")

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("a destroy in a local scene undoes, and Clear ends it", function()
    const Sandbox = Scenes.new({Name = "ClientHistoryDestroy"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Obj = Copy:Create(BareId, {[TitleId] = "Doomed"})
    const LocalId = Obj.LocalId
    History:Clear()

    T:Ok(Obj:Destroy(), "destroyed")
    T:Ok(Obj.Suspended, "kept rather than ended")

    T:Ok(History:Undo(), "undone")
    T:Eq(Copy:Find(LocalId), Obj, "back as itself")
    T:Eq(Obj:Get(TitleId), "Doomed", "with what it held")

    -- Redo puts the destroy back on the undo stack, so acting again forks
    -- nothing away: the step can still be undone, and it keeps the object.
    T:Ok(History:Redo(), "redone")
    T:Ok(Obj.Suspended, "held again")

    Copy:Create(BareId, {[TitleId] = "Later"})
    T:Ok(Obj.Suspended, "still held by the step under the new one")

    -- Clear is what lets go of it.
    History:Clear()
    T:Eq(Obj.Suspended, nil, "and what it held is gone for good")

    Sandbox:Destroy()
end)

T:Test("a local transaction applies here and is one step", function()
    const Sandbox = Scenes.new({Name = "ClientLocalTransaction"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Standing = Copy:Create(BareId, {[TitleId] = "Standing"})
    History:Clear()

    const Applied, Created = Transactions.new()
        :Create(BareId, {[TitleId] = "One"}, Copy.Id)
        :Create(BareId, {[TitleId] = "Two"}, Copy.Id)
        :Set(Standing, TitleId, "Moved")
        :Commit()

    -- No round trip: a scene this client owns is this client's to edit, so
    -- Commit has already done it by the time it returns.
    T:Ok(Applied, "applied")
    T:Eq(#Created, 2, "two created")
    T:Eq(Standing:Get(TitleId), "Moved", "and the set landed")
    T:Eq(#Copy:GetObjects(), 3, "three objects in the copy")

    T:Ok(History:CanUndo(), "recorded")
    T:Ok(History:Undo(), "undone")

    T:Eq(#Copy:GetObjects(), 1, "the whole edit went back at once")
    T:Eq(Standing:Get(TitleId), "Standing", "including the set")

    T:Ok(History:Redo(), "redone")
    T:Eq(#Copy:GetObjects(), 3, "and came back at once")
    T:Eq(Standing:Get(TitleId), "Moved", "set and all")

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("a transaction cannot mix a local scene with the server's", function()
    const Sandbox = Scenes.new({Name = "ClientMixed"})
    if not Sandbox or not BareId or not TitleId or not Editable then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Mine = Copy:Create(BareId, {[TitleId] = "Mine"})

    -- Half of this would have to be asked for and could come back refused, with
    -- the other half already applied. There is no atomicity to be had, so it is
    -- refused where it is built rather than half done.
    const Edit = Transactions.new()
        :Set(Mine, TitleId, "Local")
        :Set(Editable, TitleId, "Server")

    T:Ok(Edit.Rejected > 0, "the second kind was rejected")
    T:Ok(not Edit:Commit(), "and it refuses to commit")
    T:Eq(Mine:Get(TitleId), "Mine", "nothing applied")

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("a local transaction destroys as one step, and undoes as the same objects", function()
    const Sandbox = Scenes.new({Name = "ClientLocalDestroy"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const First = Copy:Create(BareId, {[TitleId] = "First"})
    const Second = Copy:Create(BareId, {[TitleId] = "Second"})
    History:Clear()

    T:Ok(Transactions.new():Destroy(First):Destroy(Second):Commit(), "applied")
    T:Ok(First.Suspended and Second.Suspended, "both kept rather than ended")
    T:Eq(#Copy:GetObjects(), 0, "and both gone")

    T:Ok(History:Undo(), "undone")
    T:Eq(Copy:Find(First.LocalId), First, "the same object back")
    T:Eq(Copy:Find(Second.LocalId), Second, "and the other")

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("a pack places into a copy this client owns", function()
    const Source = Scenes.new({Name = "ClientPlaceSource"})
    if not Source or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const SourceCopy = Source:Load()
    SourceCopy:Create(BareId, {[TitleId] = "PackOne"})
    SourceCopy:Create(BareId, {[TitleId] = "PackTwo"})
    const Pack = SourceCopy:Serialize()
    Source:Destroy()

    const Target = Scenes.new({Name = "ClientPlaceTarget"})
    if not Target then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Target:Load()
    const Sitting = Copy:Create(BareId, {[TitleId] = "Sitting"})

    const Made = Copy:Place(Pack)
    T:Ok(Made and #Made == 2, "both objects placed")

    if Made then
        T:Eq(#Copy:GetObjects(), 3, "beside what was already there")

        for _, Obj in Made do
            T:Ok(Obj.LocalId ~= Sitting.LocalId, "under a fresh id")
            T:Eq(Copy:Find(Obj.LocalId), Obj, "filed under it")
            T:Ok(Obj.Local, "and owned by this client")
        end
    end

    -- One step per object: copy:Place creates them one at a time and the
    -- history records each. Placing as a single step is what the transaction
    -- form is for -- Transactions.new():Place(pack, copy.Id) -- and Scenes
    -- cannot reach for that itself without requiring the module that now
    -- requires it.
    T:Ok(History:Undo(), "undone")
    T:Eq(#Copy:GetObjects(), 2, "one object at a time")

    Target:Destroy()
    History:Clear()
end)

T:Test("a large local scene loads in frames, and whole inside a transaction", function()
    const Sandbox = Scenes.new({Name = "ClientLargeLoad"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Source = Sandbox:Load()
    for Index = 1, 3000 do
        Source:Create(BareId, {[TitleId] = `Filler{Index}`})
    end

    Source:Commit()
    Source:Unload()
    History:Clear()
    task.wait(0.2)

    -- Read directly, it hands control back at its first yield: timing the
    -- spawn times the longest stretch it holds this client without a break.
    -- It used to build all three thousand at once.
    local Copy: any = nil
    const Started = os.clock()
    task.spawn(function()
        Copy = Sandbox:Load()
    end)

    const FirstStretch = os.clock() - Started
    T:Ok(FirstStretch < 0.05, `the first stretch was short, {math.floor(FirstStretch * 1000)} ms`)
    T:Eq(Copy, nil, "and the load was still going after it")

    T:Eventually(function()
        return Copy ~= nil
    end, 10, "the load finished")

    if Copy then
        T:Eq(#Copy:GetObjects(), 3000, "every object was read")
        Copy:Unload()
    end

    -- A local transaction applies on the spot and does not yield, so a load
    -- inside one is whole by the time Commit returns.
    T:Ok(Transactions.new():Load(Sandbox.Id):Commit(), "loaded through a transaction")
    const Whole = Sandbox:GetInstances()[1]
    T:Ok(Whole and #Whole:GetObjects() == 3000, "and whole when Commit returned")

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("a local copy set aside while it is read comes back whole", function()
    const Sandbox = Scenes.new({Name = "ClientAsideLoad"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Source = Sandbox:Load()
    for Index = 1, 3000 do
        Source:Create(BareId, {[TitleId] = `Aside{Index}`})
    end

    Source:Commit()
    Source:Unload()
    History:Clear()

    local Loaded: any = nil
    task.spawn(function()
        Loaded = Sandbox:Load()
    end)

    const Copy = Sandbox:GetInstances()[1]
    T:Ok(Copy and Copy:Suspend(), "set aside mid-read")

    T:Eventually(function()
        return Loaded ~= nil
    end, 10, "the load returned")

    if Copy then
        T:Ok(Copy:Revive(), "brought back")
        T:Eq(#Copy:GetObjects(), 3000, "with every object in it")
    end

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("a local scene loading its own pack is not a step", function()
    const Sandbox = Scenes.new({Name = "ClientHistoryLoad"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    Copy:Create(BareId, {[TitleId] = "One"})
    Copy:Create(BareId, {[TitleId] = "Two"})
    Copy:Commit()
    Copy:Unload()

    History:Clear()
    Sandbox:Load()

    -- Reading a pack back is not something anybody did, and a level of five
    -- hundred objects is not five hundred undo steps.
    T:Ok(not History:CanUndo(), "nothing recorded")

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("an action of the game's own sits in the same order", function()
    const Sandbox = Scenes.new({Name = "ClientHistoryCustom"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Obj = Copy:Create(BareId, {[TitleId] = "Start"})
    History:Clear()

    -- Pushed as the action happens, so it starts where the action left it.
    local Where = "after"
    local Held = true

    T:Ok(History:Push({
        Undo = function()
            Where = "before"
        end,

        Redo = function()
            Where = "after"
        end,

        Clear = function()
            Held = false
        end,
    }), "pushed")

    -- An edit after it, so the action is not the one on top.
    Obj:Set(TitleId, "Edited")

    T:Ok(History:Undo(), "the edit undone")
    T:Eq(Obj:Get(TitleId), "Start", "the edit went back")
    T:Eq(Where, "after", "and the action has not been reached yet")

    T:Ok(History:Undo(), "the action undone")
    T:Eq(Where, "before", "its Undo ran")

    T:Ok(History:Redo(), "and redone")
    T:Eq(Where, "after", "its Redo ran")

    T:Ok(Held, "still holding what it holds")
    History:Clear()
    T:Ok(not Held, "and let go when nothing can reach it")

    Sandbox:Destroy()
end)

T:Test("a custom action that throws stays on the stack", function()
    History:Clear()

    T:Ok(History:Push({
        Undo = function()
            error("no")
        end,

        Redo = function() end,
    }), "pushed")

    T:Ok(not History:Undo(), "refused")
    T:Ok(History:CanUndo(), "and left where it was")

    History:Clear()
end)

T:Test("a custom undo's own edits go unrecorded, the player's meanwhile do not", function()
    const Sandbox = Scenes.new({Name = "ClientCustomOwn"})
    if not Sandbox or not BareId or not TitleId then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    const Obj = Copy:Create(BareId, {[TitleId] = "Before"})
    History:Clear()

    History:Push({
        Undo = function()
            Obj:Set(TitleId, "ByAction")
            task.wait(0.3)
        end,

        Redo = function() end,
    })

    local Undone = nil
    task.spawn(function()
        Undone = History:Undo()
    end)

    -- One flag held across the action's wait used to drop this as well. Made
    -- while the action is still waiting, and too late to merge into anything.
    task.wait(0.05)
    Obj:Set(TitleId, "ByPlayer")

    T:Eventually(function()
        return Undone ~= nil
    end, 3, "the undo finished")

    -- Before undoing the edit, which puts the edit itself on the redo stack.
    T:Ok(not History:CanRedo(), "the undone action is not redoable past the newer edit")
    T:Ok(History:CanUndo(), "the player's edit is a step")
    T:Ok(History:Undo(), "and undoes")
    T:Eq(Obj:Get(TitleId), "ByAction", "back to what the action left")
    T:Ok(not History:CanUndo(), "and the action's own edit was never a step")

    Sandbox:Destroy()
    History:Clear()
end)

T:Test("a custom action needs both verbs", function()
    History:Clear()
    T:Ok(not History:Push({Undo = function() end} :: any), "refused without a Redo")
    T:Ok(not History:CanUndo(), "and nothing was recorded")
end)

T:Test("clearing lands in order with the edits around it", function()
    if not Editable or not TitleId then
        T:Ok(false, "no editable fixture")
        return
    end

    -- An edit straight after a clear. The clear used to cross on the remote
    -- event and the set on the remote function, and the clear landed second
    -- and wiped the step the set had just made.
    Window()
    History:Clear()
    Editable:Set(TitleId, "ClearedBefore")

    T:Eventually(function()
        return History:CanUndo()
    end, 3, "the edit after the clear was recorded")

    task.wait(0.5)
    T:Ok(History:CanUndo(), "and stayed recorded")

    -- And the other way round: an edit straight before a clear is cleared.
    Window()
    Editable:Set(TitleId, EDITABLE_MARKER)
    History:Clear()

    task.wait(1)
    T:Ok(not History:CanUndo(), "the edit before the clear went with it")
end)

T:Test("a transaction is a step the server keeps", function()
    if not BareId or not TitleId then
        T:Ok(false, "no bare registry")
        return
    end

    History:Clear()
    Window()

    const Applied, Created = Transactions.new()
        :Create(BareId, {[TitleId] = "Undoable"})
        :Commit()

    T:Ok(Applied, "created")

    const Made = Created[1]
    T:Eventually(function()
        return Made and Objects:Get(Made)
    end, 3, "the object arrived")

    -- Recorded on the server, which tells this side where the step sits in the
    -- order and nothing else about it.
    T:Eventually(function()
        return History:CanUndo()
    end, 3, "and the commit was recorded")

    Window()
    T:Ok(History:Undo(), "undone")
    T:Eventually(function()
        return Objects:Get(Made) == nil
    end, 3, "the create was taken back")

    Window()
    T:Ok(History:Redo(), "redone")

    const Again = T:Eventually(function()
        return FindLiveObject(BareId, TitleId, "Undoable")
    end, 3, "made again")

    if Again then
        -- The same object, not a replacement: the server withdrew it rather
        -- than destroying it, so it came back under the id it always had.
        T:Eq(Again.RuntimeId, Made, "under the same runtime id")
        Window()
        Again:Destroy()
    end

    History:Clear()
end)

T:Test("a lone destroy of a server object is undoable", function()
    if not BareId or not TitleId then
        T:Ok(false, "no bare registry")
        return
    end

    History:Clear()
    Window()

    const Applied, Created = Transactions.new()
        :Create(BareId, {[TitleId] = "Loner"})
        :Commit()

    T:Ok(Applied, "created")

    const Made = Created[1]
    const Obj = T:Eventually(function()
        return Made and Objects:Get(Made)
    end, 3, "the object arrived")

    if not Obj then
        return
    end

    History:Clear()
    Window()

    -- Object:Destroy on its own, which used to be the one edit nothing could
    -- take back: it goes down a channel of its own, and the stack that records
    -- it is now on the side that channel lands on.
    T:Ok(Obj:Destroy(), "destroyed")
    T:Eventually(function()
        return Objects:Get(Made) == nil
    end, 3, "gone")

    T:Eventually(function()
        return History:CanUndo()
    end, 3, "and recorded")

    Window()
    T:Ok(History:Undo(), "undone")

    const Back = T:Eventually(function()
        return Objects:Get(Made)
    end, 3, "back again")

    if Back then
        T:Eq(Back.RuntimeId, Made, "as the same object")
        Window()
        Back:Destroy()
    end

    History:Clear()
end)

--=============================================================================

if not T:Report() then
    error("[ PRISM TEST ] Client suite failed; see the failures above.", 0)
end
