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
-- A copy's node is a Model rather than a Folder so that a copy can still be
-- placed: PivotTo moves the whole room at once. That is what a Container was
-- really for, and it is easier this way round, since the framework hands you
-- the model rather than asking you to supply one.

const RunService = game:GetService("RunService")
const Logger = require("./Logger")

const IS_SERVER = RunService:IsServer()
const ROOT_NAME = "__prism"
const WAIT_TIMEOUT = 10

const World = {}

World.RootName = ROOT_NAME

local Root: Instance? = nil

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
        local Found = workspace:FindFirstChild(ROOT_NAME)
        if not Found then
            const Folder = Instance.new("Folder")
            Folder.Name = ROOT_NAME
            Folder.Parent = workspace
            Found = Folder
        end

        Root = Found
        return Found
    end

    const Found = workspace:WaitForChild(ROOT_NAME, WAIT_TIMEOUT)
    if not Found then
        Logger:Error(`Waited {WAIT_TIMEOUT}s for workspace.{ROOT_NAME}, which the server creates. Is Prism required on the server?`)
    end

    Root = Found
    return Found
end

World.GetRoot = GetRoot

-- The model a copy's objects are parented into, built on the way down if it is
-- not there yet. Idempotent: a copy asks for it once, but a client rendering a
-- copy of a scene the server also holds finds the folder already there.
function World.Copy(Scene: number, Copy: number): Model
    const RootFolder = GetRoot()

    local SceneFolder = RootFolder:FindFirstChild(SceneName(Scene))
    if not SceneFolder then
        const Folder = Instance.new("Folder")
        Folder.Name = SceneName(Scene)
        Folder.Parent = RootFolder
        SceneFolder = Folder
    end

    local CopyModel = (SceneFolder :: Instance):FindFirstChild(CopyName(Copy))
    if not CopyModel then
        const Model = Instance.new("Model")
        Model.Name = CopyName(Copy)
        Model.Parent = SceneFolder
        CopyModel = Model
    end

    return CopyModel :: Model
end

-- Takes the copy's model and everything parented to it. The scene's folder goes
-- with the last of its copies, so an unloaded scene leaves nothing behind.
function World.DropCopy(Scene: number, Copy: number)
    const RootFolder = GetRoot()

    const SceneFolder = RootFolder:FindFirstChild(SceneName(Scene))
    if not SceneFolder then
        return
    end

    const CopyModel = SceneFolder:FindFirstChild(CopyName(Copy))
    if CopyModel then
        CopyModel:Destroy()
    end

    if #SceneFolder:GetChildren() == 0 then
        SceneFolder:Destroy()
    end
end

return World
