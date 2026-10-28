--!strict
-- The tree Prism owns in the workspace.
--
-- An object's instance used to be parented wherever a Container field named:
-- one on the object registry, one on the scene, one on the copy, resolved in
-- that order. Three places to set it, three chances for them to disagree, and
-- nothing in the explorer to say which room a part belonged to. There is one
-- place instead, and the framework owns it:
--
--     workspace.__prism.__scene_{SceneId}.__copy_{CopyId}
--
-- Keyed by the copy rather than by the scene, because a scene loaded five times
-- is five copies and they cannot share a folder -- the same reason objects are
-- filed by copy everywhere else.
--
-- That tree is only where a copy goes when nobody says otherwise. Load takes a
-- parent, and a copy's folder is parented wherever it is handed -- PlayerGui
-- for a scene made of interfaces, a Model of your own if you want to pivot it,
-- Lighting for a scene of atmospheres. A Folder can be parented anywhere, which
-- is the whole reason it is a Folder: the framework has no business knowing
-- what class your objects are or where that class belongs.

const RunService = game:GetService("RunService")
const Logger = require("./Logger")

const IS_SERVER = RunService:IsServer()
const ROOT_NAME = "__prism"
const WAIT_TIMEOUT = 10

const World = {}

World.RootName = ROOT_NAME

local Root: Instance? = nil

-- Scene folders this side built, by scene. Kept by reference rather than found
-- by name: a client builds folders of its own for the copies it draws, and the
-- server may have replicated one by the same name for its own copies of that
-- scene. Found by name, a client could file its drawing into the server's
-- folder -- and then, emptying it, destroy the server's folder on its own side.
const Built: {[number]: Instance} = {}

const function SceneName(Scene: number): string
    return `__scene_{Scene}`
end

const function CopyName(Copy: number): string
    return `__copy_{Copy}`
end

-- The server builds the root and it replicates from there. A client waits for
-- it rather than building one of its own: two folders named __prism under the
-- workspace would make every lookup here ambiguous, and which one a client got
-- would depend on replication timing.
--
-- Resolved on first use rather than at require, so a client that never draws
-- anything never waits for it.
const function GetRoot(): Instance
    const Current = Root
    if Current and Current.Parent then
        return Current
    end

    if IS_SERVER then
        const Existing = workspace:FindFirstChild(ROOT_NAME)
        if Existing then
            Root = Existing
            return Existing
        end

        const Folder = Instance.new("Folder")
        Folder.Name = ROOT_NAME
        Folder.Parent = workspace
        Root = Folder
        return Folder
    end

    const Found = workspace:WaitForChild(ROOT_NAME, WAIT_TIMEOUT)
        or Logger:Error(`Waited {WAIT_TIMEOUT}s for workspace.{ROOT_NAME}, which the server creates. Is Prism required on the server?`)

    Root = Found
    return Found
end

World.GetRoot = GetRoot

-- Built as the server starts rather than on first use, so it is there to
-- replicate before any client goes looking. A server whose copies are all
-- opened rather than loaded never parents anything here itself, and its
-- clients -- who draw those copies -- would otherwise wait for a root that
-- nothing was ever going to make.
if IS_SERVER then
    GetRoot()
end

-- Where a copy goes when its loader named no parent of its own. Built on the
-- way down, and shared by every copy of that scene that also named none.
const function DefaultParent(Scene: number): Instance
    const Existing = Built[Scene]
    if Existing and Existing.Parent then
        return Existing
    end

    const Folder = Instance.new("Folder")
    Folder.Name = SceneName(Scene)
    Folder.Parent = GetRoot()
    Built[Scene] = Folder
    return Folder
end

-- The folder a copy's objects are parented into. Named for the copy rather than
-- the scene, because a scene loaded five times is five copies and they cannot
-- share one -- the same reason objects are filed by copy everywhere else.
--
-- Never yields. A client whose root has not replicated yet gets its folder back
-- unparented and parented once the root arrives: the caller is often a network
-- handler, and a handler that waited here would let the next packet -- the
-- copy's objects -- be handled before the copy it belongs to was set up. What
-- is drawn into the folder meanwhile appears with it. A folder the caller has
-- placed somewhere of its own by then is left where it was put.
-- Puts a copy's folder where it belongs, which is wherever the caller said or
-- the scene's own place in the tree. Separate from making one because a copy
-- withdrawn from the world keeps its folder and needs putting back: what comes
-- back has to be the folder that left, with whatever the game had parented to
-- it, and a fresh one would not be.
function World.Place(Folder: Folder, Scene: number, Parent: Instance?)
    if Parent and Parent.Parent ~= nil then
        Folder.Parent = Parent
        return
    end

    -- The parent it was under has been destroyed since, or there never was one.
    -- Either way the scene's own place in the tree is the answer.
    if IS_SERVER or (Root and Root.Parent) or workspace:FindFirstChild(ROOT_NAME) then
        Folder.Parent = DefaultParent(Scene)
        return
    end

    task.spawn(function()
        const Resolved = DefaultParent(Scene)
        if Folder.Parent == nil then
            pcall(function()
                Folder.Parent = Resolved
            end)
        end
    end)
end

function World.Copy(Scene: number, Copy: number, Parent: Instance?): Folder
    const Folder = Instance.new("Folder")
    Folder.Name = CopyName(Copy)

    if Parent then
        Folder.Parent = Parent
    elseif IS_SERVER or (Root and Root.Parent) or workspace:FindFirstChild(ROOT_NAME) then
        Folder.Parent = DefaultParent(Scene)
    else
        task.spawn(function()
            const Resolved = DefaultParent(Scene)
            if Folder.Parent == nil then
                pcall(function()
                    Folder.Parent = Resolved
                end)
            end
        end)
    end

    return Folder
end

-- Takes the copy's folder and everything parented to it. A default scene folder
-- goes with the last of its copies, so an unloaded scene leaves nothing behind;
-- a parent the caller supplied is the caller's and is left alone.
function World.DropCopy(Scene: number, Folder: Instance?)
    if Folder then
        Folder:Destroy()
    end

    const SceneFolder = Built[Scene]
    if SceneFolder and #SceneFolder:GetChildren() == 0 then
        SceneFolder:Destroy()
        Built[Scene] = nil
    end
end

return World
