--!strict
const Networking = require("../Networking")

return {
    SceneRegistered = Networking:Get("Scenes.SceneRegistered"),
    SceneUnregistered = Networking:Get("Scenes.SceneUnregistered"),
    RegistriesReplayed = Networking:Get("Scenes.RegistriesReplayed"),

    InstanceAdded = Networking:Get("Scenes.InstanceAdded"),
    InstanceRemoved = Networking:Get("Scenes.InstanceRemoved"),
    InstancesReplayed = Networking:Get("Scenes.InstancesReplayed"),
}
