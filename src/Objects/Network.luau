const Networking = require("../Networking")
return {
    ObjectRegistered = Networking:Register("Objects.ObjectRegistered"),

    ObjectAdded = Networking:Register("Objects.ObjectAdded"),
    ObjectRemoved = Networking:Register("Objects.ObjectRemoved"),
    PropertyChanged = Networking:Register("Objects.PropertyChanged"),

    SetProperty = Networking:Register("Objects.SetProperty"),
    Destroy = Networking:Register("Objects.Destroy")
}