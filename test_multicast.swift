import Foundation
import Network

let mGroup = try! NWMulticastGroup(for: [.hostPort(host: "227.0.0.1", port: 4001)])
let group = NWConnectionGroup(with: mGroup, using: .udp)
group.stateUpdateHandler = { state in
    print("State: \(state)")
}
group.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: false) { message, content, isComplete in
    print("Received \(content?.count ?? 0) bytes")
}
group.start(queue: .main)
RunLoop.main.run(until: Date().addingTimeInterval(5))
