import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VoiceDraftCore

/// "Pair another device": a QR code and a copyable `voicedraft://sync` link built from the saved
/// connection. The link carries the access token and passphrase, so it is built only when the user asks,
/// kept only in view state, and dropped when the panel closes.
struct PairingCodeView: View {
    @ObservedObject var state: AppState
    @State private var expanded = false
    @State private var code: NSImage?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: VD.Space.s) {
                Text(D("The code and link contain the access token and passphrase. Show them only to your own devices."))
                    .font(VD.Font.detail).foregroundStyle(VD.Palette.warning).fixedSize(horizontal: false, vertical: true)
                if let code {
                    Image(nsImage: code).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .accessibilityLabel(D("Pairing code"))
                    Text(D("Scan with the iPhone camera, or copy the link and open it on the device."))
                        .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(code == nil ? D("Show pairing code") : D("Hide pairing code")) {
                        if code == nil { code = makeLink().flatMap(Self.qrImage) } else { code = nil }
                    }
                    Button(D("Copy pairing link")) { copyLink() }
                }
            }
            .padding(.top, VD.Space.s)
        } label: {
            Text(D("Pair another device")).font(VD.Font.cardTitle)
        }
        .onChange(of: expanded) { open in if !open { code = nil } }
        .onDisappear { code = nil }
    }

    /// Built from the saved connection, not the unsaved text fields.
    private func makeLink() -> URL? {
        do {
            return try SyncPairingLink.build(serverURL: state.device.serverURL, token: state.syncToken(),
                                             passphrase: state.syncPassphrase())
        } catch {
            state.error = .init(error: error)
            return nil
        }
    }

    private func copyLink() {
        guard let link = makeLink() else { return }
        let board = NSPasteboard.general
        board.clearContents()
        // Marked concealed and transient so clipboard managers skip the secret.
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                            NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        board.setString(link.absoluteString, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    static func qrImage(_ link: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
