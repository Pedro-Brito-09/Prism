--!strict
const Networking = require("../Networking")

return {
    Undo = Networking:Get("History.Undo"),
    Redo = Networking:Get("History.Redo"),
    Changed = Networking:Get("History.Changed"),
    Forget = Networking:Get("History.Forget"),
}
