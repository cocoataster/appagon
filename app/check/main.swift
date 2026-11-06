import Foundation

// Checks on the Mac, without Xcode or a simulator, that the Swift version of the rules, calculators
// and synonyms gives exactly the same results as eval/pipeline.py.
//
//   swiftc -O Sources/Pipeline.swift check/main.swift -o build/check && build/check Contenido/datos

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Contenido/datos"
let folder = URL(fileURLWithPath: path)
do {
    let p = try Pipeline(folder: folder)
    let cases = try JSONDecoder().decode([TestCase].self, from: Data(contentsOf: folder.appendingPathComponent("casos.json")))
    let r = Verification.pureLogic(p, cases)
    print(r.text)
    let s = Verification.safetyNet(p)
    print(s.text)
    exit(r.failures + s.failures == 0 ? 0 : 1)
} catch {
    print("Error: \(error)")
    exit(2)
}
