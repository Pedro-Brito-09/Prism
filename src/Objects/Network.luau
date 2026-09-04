const Networking = require("../Networking")
return {
    ObjectRegistered = Networking:Get("Objects.ObjectRegistered"),

    ObjectAdded = Networking:Get("Objects.ObjectAdded"),
    ObjectRemoved = Networking:Get("Objects.ObjectRemoved"),
    PropertyChanged = Networking:Get("Objects.PropertyChanged"),

    SetProperty = Networking:Get("Objects.SetProperty"),
    Destroy = Networking:Get("Objects.Destroy"),
}
