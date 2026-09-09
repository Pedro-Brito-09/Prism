--!strict
const Networking = require("../Networking")

return {
    SceneRegistered = Networking:Get("Scenes.SceneRegistered"),
    SceneUnloaded = Networking:Get("Scenes.SceneUnloaded"),
    RegistriesReplayed = Networking:Get("Scenes.RegistriesReplayed"),
}
