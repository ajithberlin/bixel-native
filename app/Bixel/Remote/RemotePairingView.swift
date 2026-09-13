// RemotePairingView.swift
//
// Pairing UI for Bixel Remote. The Mac shows a time-limited QR code; the iPad
// scans it (or pastes the pairing link). Once paired, both sides can reconnect
// without a code.

import SwiftUI
import CoreImage
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// Render a QR code for a pairing URL.
func remoteQRImage(from string: String) -> PlatformImage? {
    let data = Data(string.utf8)
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return makePlatformImage(cgImage: cg)
}

/// Settings pane entry point, specialized per platform.
struct RemoteSettingsPane: View {
    var body: some View {
        #if os(macOS)
        RemoteHostSettingsView()
        #else
        RemoteClientSettingsView()
        #endif
    }
}

#if os(macOS)

private struct RemoteHostSettingsView: View {
    @ObservedObject private var host = RemoteHost.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Devices")
                    .font(.system(size: 18, weight: .semibold))
                Text("Pair an iPad on the same Wi‑Fi to sync projects and use the Bixel assistant, which runs here on your Mac.")
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(spacing: 12) {
                        if let offer = host.pairingOffer, let image = remoteQRImage(from: offer.urlString()) {
                            Image(platformImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 220, height: 220)
                                .padding(8)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                            Text("Scan with Bixel on your iPad")
                                .font(.system(size: 12, weight: .medium))
                            Text("Code expires in \(host.pairingSecondsRemaining)s")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            Button("Hide code") { host.endPairing() }
                        } else {
                            Image(systemName: "qrcode")
                                .font(.system(size: 42, weight: .light))
                                .foregroundColor(StudioTheme.textDisabled)
                            Text(host.status)
                                .font(.system(size: 12))
                                .foregroundColor(StudioTheme.textSecondary)
                            Button("Show pairing code") { host.beginPairing() }
                                .buttonStyle(.borderedProminent)
                                .tint(StudioTheme.accent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                }

                if !host.peers.isEmpty {
                    GroupBox("Paired devices") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(host.peers.enumerated()), id: \.offset) { _, name in
                                HStack {
                                    Image(systemName: "ipad")
                                    Text(name)
                                    Spacer()
                                }
                                .font(.system(size: 12))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { host.start() }
    }
}

#elseif os(iOS)

private struct RemoteClientSettingsView: View {
    @ObservedObject private var client = RemoteClient.shared
    @State private var scanning = false
    @State private var manualLink = ""
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect to your Mac")
                    .font(.system(size: 18, weight: .semibold))
                Text("On your Mac, open Settings → Devices and show the pairing code. Scan it here over the same Wi‑Fi to sync projects and use the Bixel assistant running on the Mac.")
                    .font(.system(size: 12))
                    .foregroundColor(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Circle()
                        .fill(client.state.isConnected ? StudioTheme.bixelGreen : StudioTheme.textDisabled)
                        .frame(width: 8, height: 8)
                    Text(client.state.label).font(.system(size: 12, weight: .medium))
                    Spacer()
                }

                Button {
                    scanning = true
                } label: {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Or paste the pairing link")
                        .font(.system(size: 11))
                        .foregroundColor(StudioTheme.textSecondary)
                    TextField("bixel://pair?…", text: $manualLink)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect") { connect(manualLink) }
                        .disabled(RemotePairingOffer.parse(manualLink) == nil)
                }

                if !client.trustedHosts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paired Macs")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(client.trustedHosts) { peer in
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(peer.name).font(.system(size: 12))
                                Spacer()
                                Button("Reconnect") { client.reconnect(to: peer) }
                                    .font(.system(size: 11))
                                Button("Forget") { client.forget(peer) }
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }

                if client.state.isConnected {
                    Button("Disconnect", role: .destructive) { client.disconnect() }
                }
                if let message {
                    Text(message).font(.system(size: 11)).foregroundColor(.orange)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $scanning) {
            RemoteScannerView { code in
                scanning = false
                connect(code)
            }
        }
    }

    private func connect(_ link: String) {
        guard let offer = RemotePairingOffer.parse(link) else {
            message = "That pairing link is not valid."
            return
        }
        message = nil
        client.pair(offer: offer)
    }
}

/// A minimal AVFoundation QR scanner.
struct RemoteScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> RemoteScannerController {
        let controller = RemoteScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: RemoteScannerController, context: Context) {}
}

final class RemoteScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        handled = true
        session.stopRunning()
        onCode?(value)
    }
}

#endif
