import SwiftUI
import AppKit

/// Identificador de la escena `Window`, usado por `openWindow(id:)` desde el menú.
let aboutWindowID = "about"

let donationURL = URL(string: "https://www.paypal.com/donate/?hosted_button_id=Q2E7M3ZS53NF8")!
/// Requisito de la GPL-3: quien recibe el binario tiene que poder llegar al código
/// fuente. Por eso el link vive en la ventana About y no solo en el README.
let repositoryURL = URL(string: "https://github.com/jcubillosz/gnote-plus-plus")!
let gplURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

private struct Credit {
    let component: String
    let author: String
    let license: String
}

// No se traducen: son nombres propios y designaciones de licencia.
private let credits: [Credit] = [
    Credit(component: "Notepad++", author: "Don Ho", license: "GPL-3.0"),
    Credit(component: "Scintilla · Lexilla", author: "Neil Hodgson", license: "HPND"),
    Credit(component: "uchardet", author: "Mozilla · Free Software Foundation", license: "MPL-1.1"),
    Credit(component: "pugixml", author: "Arseny Kapoulkine", license: "MIT"),
    Credit(component: "cmark-gfm", author: "John MacFarlane · GitHub", license: "BSD-2")
]

struct AboutView: View {
    /// Leída del bundle y nunca hardcodeada: escrita a mano se desincroniza del
    /// Info.plist en el primer release y nadie lo nota.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                donation
                Divider()
                creditsSection
            }
            .padding(24)
        }
        .frame(width: 460, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text("GNote++")
                    .font(.system(size: 26, weight: .semibold))
                Text(L("Versión \(version)"))
                    .foregroundStyle(.secondary)
                Text(L("Editor de texto para macOS, basado en el código de Notepad++."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var donation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Gracias por utilizar GNote++"))
                .font(.headline)
            Text(L("Puedes contribuir al desarrollo de mejoras donando en el siguiente enlace."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Apoyar el proyecto ☕")) {
                NSWorkspace.shared.open(donationURL)
            }
            .controlSize(.large)
        }
    }

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Créditos y licencias"))
                .font(.headline)

            ForEach(credits, id: \.component) { credit in
                VStack(alignment: .leading, spacing: 1) {
                    Text(credit.component)
                        .font(.callout.weight(.medium))
                    Text("\(credit.author) — \(credit.license)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(L("GNote++ se distribuye bajo la GPL-3.0. Eso incluye el derecho a obtener, modificar y redistribuir su código fuente."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 16) {
                Link(L("Código fuente"), destination: repositoryURL)
                Link(L("Texto de la licencia"), destination: gplURL)
            }
            .font(.callout)
        }
    }
}
