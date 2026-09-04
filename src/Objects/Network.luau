--!strict
const Networking = require("../Networking")
return {
    ObjectRegistered = Networking:Get("Objects.ObjectRegistered"),
    RegistriesReplayed = Networking:Get("Objects.RegistriesReplayed"),
    ObjectsReplayed = Networking:Get("Objects.ObjectsReplayed"),

    ObjectAdded = Networking:Get("Objects.ObjectAdded"),
    ObjectRemoved = Networking:Get("Objects.ObjectRemoved"),
    PropertyChanged = Networking:Get("Objects.PropertyChanged"),

    SetProperty = Networking:Get("Objects.SetProperty"),
    Destroy = Networking:Get("Objects.Destroy"),
}
