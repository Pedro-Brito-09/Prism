--!strict
const Networking = require("../Networking")
return {
    ObjectRegistered = Networking:Get("Objects.ObjectRegistered"),
    RegistriesReplayed = Networking:Get("Objects.RegistriesReplayed"),
    ObjectUnregistered = Networking:Get("Objects.ObjectUnregistered"),
    ObjectsReplayed = Networking:Get("Objects.ObjectsReplayed"),

    ObjectAdded = Networking:Get("Objects.ObjectAdded"),
    ObjectRemoved = Networking:Get("Objects.ObjectRemoved"),
    PropertyChanged = Networking:Get("Objects.PropertyChanged"),

    -- The bulk forms, for a transaction. One packet per operation is what the
    -- chunked paths exist to avoid.
    ObjectsRemoved = Networking:Get("Objects.ObjectsRemoved"),
    PropertiesChanged = Networking:Get("Objects.PropertiesChanged"),

    SetProperty = Networking:Get("Objects.SetProperty"),
    Destroy = Networking:Get("Objects.Destroy"),
}
