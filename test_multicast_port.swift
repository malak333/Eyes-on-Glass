import Foundation
import Network

let mGroup = try! NWMulticastGroup(for: [.hostPort(host: "227.0.0.1", port: 4001)])
let parameters = NWParameters.udp
parameters.allowLocalEndpointReuse = true
parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("0.0.0.0"), port: 4001)

let group = NWConnectionGroup(with: mGroup, using: parameters)
group.stateUpdateHandler = { state in print("State: \(state)") }
group.start(queue: .main)
RunLoop.main.run(until: Date().addingTimeInterval(2))
