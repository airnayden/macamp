import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: SpikeController

    var body: some View {
        VStack(spacing: 14) {
            Text("MacAMP — Phase 0 Audio Spike")
                .font(.headline)

            MetalSpectrumView(ringBuffer: controller.ringBuffer)
                .frame(maxWidth: .infinity, minHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))

            HStack(spacing: 10) {
                Button("FLAC") { controller.playFLAC() }
                Button("MP3") { controller.playMP3() }
                Button("Enqueue MP3") { controller.enqueueMP3Gapless() }
                Button(controller.eqEngaged ? "EQ: CUT" : "EQ: FLAT") { controller.toggleEQ() }
                    .tint(controller.eqEngaged ? .orange : .gray)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text("status: \(controller.status)")
                Text("tap samples: \(controller.samplesWritten)")
                Text(String(format: "fft peak: %.3f    window rms: %.4f",
                            controller.fftPeak, controller.windowRMS))
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 440)
        .onAppear { controller.autoStart() }
    }
}
