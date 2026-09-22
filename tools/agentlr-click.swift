// agentlr-click: 极简 dsh-cua 客户端，提供「坐标点击 / 悬停 / 按键」三种操作。
//
// 用途：Lightroom 的菜单项对 AppleScript 的 click 返回 -1728、对 AXPress 也无响应
// （LR 自绘菜单），唯一可行的是 CGEvent 合成事件。其中**子菜单必须靠悬停展开**
// —— 点击父项会执行动作并关闭菜单，只有把指针移到父项上停留才会展开子菜单。
//
// 编译：swiftc -O -o agentlr-click agentlr-click.swift
// 用法：agentlr-click click <x> <y>
//       agentlr-click hover <x> <y>
//       agentlr-click key   <键名>
import Foundation

let binary = "/Users/tristan/Applications/dsh-cua.app/Contents/MacOS/dsh-cua"
let app = "com.adobe.LightroomClassicCC7"
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: agentlr-click click|hover <x> <y> | key <name>\n".data(using: .utf8)!)
    exit(2)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: binary)
proc.arguments = ["mcp"]
let inPipe = Pipe(), outPipe = Pipe()
proc.standardOutput = outPipe
proc.standardError = Pipe()
proc.standardInput = inPipe
try proc.run()
let stdin = inPipe.fileHandleForWriting
let stdout = outPipe.fileHandleForReading

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
    stdin.write((String(data: d, encoding: .utf8)! + "\n").data(using: .utf8)!)
}

func readResponse(id: Int) -> [String: Any]? {
    var pending = ""
    for _ in 0..<600 {
        let chunk = stdout.availableData
        if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
        guard let text = String(data: chunk, encoding: .utf8) else { continue }
        pending += text
        let lines = pending.components(separatedBy: "\n")
        pending = lines.last ?? ""
        for line in lines.dropLast() where !line.isEmpty {
            if let o = try? JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as? [String: Any],
               let rid = o["id"] as? Int, rid == id { return o }
        }
    }
    return nil
}

func callTool(_ name: String, _ arguments: [String: Any]) -> String {
    send(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
          "params": ["name": name, "arguments": arguments]])
    guard let resp = readResponse(id: 2),
          let result = resp["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let text = content.first?["text"] as? String else { return "failed" }
    return text
}

send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
    "protocolVersion": "2024-11-05", "capabilities": [:],
    "clientInfo": ["name": "agentlr-click", "version": "1.0"],
]])
_ = readResponse(id: 1)
send(["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]])

let mode = args[0]
if mode == "key" {
    print(callTool("press_key", ["app": app, "key": args[1]]))
} else {
    guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
        FileHandle.standardError.write("x/y required\n".data(using: .utf8)!)
        exit(2)
    }
    if mode == "hover" {
        print(callTool("move_mouse", ["x": x, "y": y]))
    } else {
        print(callTool("click", ["app": app, "x": x, "y": y]))
    }
}
proc.terminate()
