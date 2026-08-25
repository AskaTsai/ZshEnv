import Foundation

@main
struct ZshEnvLogicTests {
    static func main() {
        precondition(ShellValueLogic.quote("abc 123") == "'abc 123'")
        precondition(ShellValueLogic.quote("it's-safe") == "'it'\\''s-safe'")
        precondition(ShellValueLogic.quote("/opt/bin:$PATH") == "\"/opt/bin:$PATH\"")
        precondition(ShellValueLogic.references(in: "$ZSH/plugins:${HOME}/bin") == ["ZSH", "HOME"])
        precondition(ShellValueLogic.references(in: "\\$PATH").isEmpty)
        precondition(ShellValueLogic.decode("\"/opt/bin:$PATH\"") == "/opt/bin:$PATH")
        precondition(ShellValueLogic.dependencyOrderViolation(in: [("A", "1"), ("B", "$A")]) == nil)
        let violation = ShellValueLogic.dependencyOrderViolation(in: [("B", "$A"), ("A", "1")])
        precondition(violation?.consumer == "B" && violation?.dependency == "A")
        precondition(ShellValueLogic.matchesSearch("path", name: "PATH", value: "/usr/bin", note: "") == true)
        precondition(ShellValueLogic.matchesSearch("home", name: "WORKDIR", value: "/opt/home/bin", note: "") == true)
        precondition(ShellValueLogic.matchesSearch("deployment", name: "API_URL", value: "https://example.test", note: "Production deployment") == true)
        precondition(ShellValueLogic.matchesSearch("   ", name: "PATH", value: "/usr/bin", note: "") == true)
        precondition(ShellValueLogic.matchesSearch("missing", name: "PATH", value: "/usr/bin", note: "Local path") == false)
        let firstID = UUID()
        let secondID = UUID()
        precondition(ShellValueLogic.reconciledSelection(current: secondID, visibleIDs: [firstID, secondID]) == secondID)
        precondition(ShellValueLogic.reconciledSelection(current: secondID, visibleIDs: [firstID]) == firstID)
        precondition(ShellValueLogic.reconciledSelection(current: firstID, visibleIDs: []) == nil)
        print("ZshEnvLogicTests: PASS")
    }
}
