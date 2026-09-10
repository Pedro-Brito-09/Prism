--!strict
--[[
    Prism test suite -- client half.

    Put this in StarterPlayerScripts with Harness.luau beside it, and run the
    server half alongside it.
    It verifies the things a server-only test cannot: that the ready handshake
    actually delivers, registries and live objects replicate, permissions
    update, and accepted/refused edits converge on the server's decision.

    It waits for the fixture the server script leaves behind, so run both.
]]

const ReplicatedStorage = game:GetService("ReplicatedStorage")

const PRISM = ReplicatedStorage:WaitForChild("Prism").src
const CRATE_OBJECT = "TestCrate"
const BARE_OBJECT = "TestBare"
const SHOWN_OBJECT = "TestShown"
const FIXTURE_PROPERTY = "TestTitle"
const DENIED_MARKER = "FixtureDenied"
const EDITABLE_MARKER = "FixtureEditable"
const DESTROY_MARKER = "FixtureDestroy"
const EVICT_MARKER = "EvictPulse"
const TIMEOUT = 15

const Prism = require(PRISM)
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
        T:Eq(Denied:GetProperty(FIXTURE_PROPERTY), Denied.Properties[TitleId], "name map built on the client too")
    end
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

T:Describe("Admission")

T:Test("a scene you were not admitted to is never mentioned", function()
    -- The admitted one first, so this does not pass merely because nothing has
    -- arrived yet.
    T:Eventually(function()
        return Scenes:Get("FixtureAdmitted")
    end, 5, "the scene beside it arrived")

    T:Eq(Scenes:Get("FixtureHidden"), nil, "not its name")

    if BareId and TitleId then
        T:Eq(FindLiveObject(BareId, TitleId, "FixtureHiddenObject"), nil, "not its object")
    end
end)

T:Test("a scene you were admitted to arrives with its copy and objects", function()
    const Admitted = Scenes:Get("FixtureAdmitted")
    T:Ok(Admitted, "its registry")

    if not Admitted or not BareId or not TitleId then
        return
    end

    T:Eq(#Scenes:GetInstances(Admitted.Id), 1, "its copy")
    T:Eventually(function()
        return FindLiveObject(BareId, TitleId, "FixtureAdmittedObject")
    end, 5, "its object")
end)

T:Test("eviction takes the scene and everything in it", function()
    const Admitted = Scenes:Get("FixtureAdmitted")
    const Obj = if BareId and TitleId
        then FindLiveObject(BareId, TitleId, "FixtureAdmittedObject")
        else nil

    if not Admitted or not Obj or not Editable or not TitleId then
        T:Ok(false, "no admitted fixture")
        return
    end

    -- The server evicts this player when the editable fixture carries the
    -- marker, the same way the permission pulse is asked for.
    Editable:Set(TitleId, EVICT_MARKER)

    T:Eventually(function()
        return Scenes:Get("FixtureAdmitted") == nil
    end, 5, "the scene went")

    T:Ok(Obj.Destroyed, "its object with it")
    T:Eq(#Scenes:GetInstances(Admitted.Id), 0, "and its copy")

    Editable:Set(TitleId, EDITABLE_MARKER)
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
        T:Eq(Made.Parent, BareId, "of the type the create named")
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

    const Accepted, Identifier = Sandbox:Push("ClientPushedRoom")
    T:Ok(Accepted, "the server took it")
    T:Ok(Identifier and Identifier > 0, "and answered with its id")

    -- It registers on the server, so its registry reaches every client -- this
    -- one included, through the same broadcast anyone else receives.
    T:Eventually(function()
        return Scenes:Get("ClientPushedRoom")
    end, 5, "the scene came back as one of the server's")

    T:Ok(Scenes:GetLocal("ClientPush"), "and the local one is still local")
    T:Ok(Copy:Find(1), "still holding its own objects")

    Sandbox:Destroy()
end)

T:Test("a pack the server may not create is refused", function()
    if not CrateId then
        T:Ok(false, "no crate registry")
        return
    end

    -- TestCrate is blacklisted for this role, and the client is never told its
    -- template, so the object has no instance -- which does not matter: what
    -- the server refuses is the type.
    const Sandbox = Scenes.new({Name = "ClientRefused"})
    if not Sandbox then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Sandbox:Load()
    Copy:Create(CrateId)
    Copy:Commit()

    Window()

    const Accepted = Sandbox:Push("ClientRefusedRoom")
    T:Ok(not Accepted, "refused")

    Sandbox:Destroy()
end)

--=============================================================================

if not T:Report() then
    error("[ PRISM TEST ] Client suite failed; see the failures above.", 0)
end
