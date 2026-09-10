--!strict
const Networking = require("../Networking")
return {
    PropertyRegistered = Networking:Get("Properties.PropertyRegistered"),
    RegistriesReplayed = Networking:Get("Properties.RegistriesReplayed"),
    PropertyUnregistered = Networking:Get("Properties.PropertyUnregistered"),
}
