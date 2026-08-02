#!/usr/bin/env swift

// Genera el ícono placeholder de GNote++ (AppResources/GNotePP.icns).
//
// Se corre a mano, una sola vez; el build NO depende de este script — el .icns
// queda versionado. Para reemplazarlo por un ícono de diseño real basta con
// dejar otro archivo en AppResources/GNotePP.icns, sin tocar código.
//
//   cd mac/NppMacPOC && swift scripts/make_icon.swift
//
// Deliberadamente no usa nada del branding de Notepad++ (ni su ícono ni su
// paleta): sacar la marca ajena es justamente el objetivo del rebrand.

import AppKit
import Foundation

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let packageRoot = scriptURL.deletingLastPathComponent()
let outputURL = packageRoot.appendingPathComponent("AppResources/GNotePP.icns")
let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("GNotePP-\(UUID().uuidString).iconset")

// Azul profundo, sin relación con la paleta de Notepad++ (verde).
let background = NSColor(srgbRed: 0.13, green: 0.26, blue: 0.47, alpha: 1)
let accent = NSColor(srgbRed: 0.35, green: 0.72, blue: 0.94, alpha: 1)

/// Dibuja el ícono a `size` puntos. Todo se expresa en fracciones del lado para
/// que las 10 variantes salgan idénticas salvo por la resolución.
func drawIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current else { return image }
    context.imageInterpolation = .high

    // El "squircle" de macOS: los íconos ocupan ~80% del lienzo, con margen.
    let inset = side * 0.06
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.2237 // proporción del contenedor de macOS Big Sur+

    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    background.setFill()
    shape.fill()

    // Barra de acento a la izquierda, como el margen de un editor.
    let bar = NSRect(x: rect.minX, y: rect.minY, width: rect.width * 0.13, height: rect.height)
    let barPath = NSBezierPath(roundedRect: bar, xRadius: radius * 0.6, yRadius: radius * 0.6)
    accent.setFill()
    barPath.fill()
    // El lado derecho de la barra queda recto: se tapa la mitad redondeada.
    NSBezierPath(rect: NSRect(x: bar.midX, y: bar.minY, width: bar.width / 2, height: bar.height)).fill()

    let text = "G++" as NSString
    let fontSize = side * 0.36
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: -fontSize * 0.02
    ]
    let textSize = text.size(withAttributes: attributes)
    // Centrado en el área a la derecha de la barra, no en el lienzo entero.
    let textArea = NSRect(x: bar.maxX, y: rect.minY, width: rect.maxX - bar.maxX, height: rect.height)
    let origin = NSPoint(
        x: textArea.midX - textSize.width / 2,
        y: textArea.midY - textSize.height / 2
    )
    text.draw(at: origin, withAttributes: attributes)

    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no se pudo crear el bitmap de \(pixels)px"])
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "no se pudo codificar el PNG de \(pixels)px"])
    }
    try data.write(to: url)
}

// Los 10 archivos exactos que iconutil espera en un .iconset.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

do {
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: iconsetURL) }

    for variant in variants {
        // Se redibuja a cada tamaño en vez de escalar uno grande: el texto de
        // 16px queda legible solo si se compone a esa resolución.
        let image = drawIcon(side: CGFloat(variant.pixels))
        try writePNG(image, pixels: variant.pixels, to: iconsetURL.appendingPathComponent(variant.name))
    }

    try? fileManager.removeItem(at: outputURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("iconutil falló con código \(process.terminationStatus)\n".utf8))
        exit(1)
    }

    let bytes = (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
    print("==> \(outputURL.path) (\(bytes) bytes)")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
