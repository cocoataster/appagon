import Foundation

// Comprueba en el Mac, sin Xcode ni simulador, que la versión en Swift de las reglas, las calculadoras
// y los sinónimos da exactamente lo mismo que eval/pipeline.py.
//
//   swiftc -O Sources/Pipeline.swift check/main.swift -o build/check && build/check Contenido/datos

let ruta = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Contenido/datos"
let carpeta = URL(fileURLWithPath: ruta)
do {
    let p = try Pipeline(carpeta: carpeta)
    let casos = try JSONDecoder().decode([Caso].self, from: Data(contentsOf: carpeta.appendingPathComponent("casos.json")))
    let r = Comprobacion.puras(p, casos)
    print(r.texto)
    let s = Comprobacion.redSeguridad(p)
    print(s.texto)
    exit(r.fallos + s.fallos == 0 ? 0 : 1)
} catch {
    print("Error: \(error)")
    exit(2)
}
