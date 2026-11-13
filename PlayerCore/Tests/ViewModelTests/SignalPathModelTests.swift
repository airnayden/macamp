// SignalPathModelTests — the signal-path panel's whole decision table (todo 17).
//
// The mapper is pure, so every case here is a value in and a value out: no engine,
// no device, no database. The six direct-path conditions are each falsified on
// their own, and two of them deliberately overlap in what they read — the graphic
// pre-amp case has FLAT bands and still refuses the badge, which is only possible
// because the gate reads `GainComposer.composedGainDB` rather than band flatness.
import AudioEngine
import Testing
@testable import ViewModels

struct SignalPathModelTests {
    /// A 44.1 kHz / 16-bit FLAC on a 44.1 kHz device with nothing engaged: the one
    /// shape that earns the badge, and no sample-rate conversion to report.
    @Test func untouchedChainAtTheDeviceRateIsADirectPath() {
        let model = SignalPathModel(Self.untouched())

        #expect(model.directPath)
        #expect(!model.srcActive)
        #expect(model.sourceRateMatchesDevice)
        #expect(model.sourceFormat == "FLAC · 44.1 kHz · 16-bit · 1411 kbps")
        #expect(model.connectionFormat == "44.1 kHz · 2 ch")
        #expect(model.deviceRateText == "44.1 kHz")
        #expect(!model.isDSD)
    }

    /// A 96 kHz source on a 48 kHz device: something between them is resampling, so
    /// the SRC indicator lights and the badge is withheld.
    @Test func sourceRateAboveTheDeviceRateReportsConversion() {
        var inputs = Self.untouched()
        inputs.sourceSampleRate = 96000
        inputs.connectionSampleRate = 96000
        inputs.deviceNominalRate = 48000
        let model = SignalPathModel(inputs)

        #expect(model.srcActive)
        #expect(!model.directPath)
        #expect(!model.sourceRateMatchesDevice)
        #expect(model.sourceSampleRateToken == "96 kHz")
        #expect(model.deviceRateText == "48 kHz")
    }

    /// A ReplayGain trim is gain, so the chain is no longer direct.
    @Test func replayGainTrimDefeatsTheDirectPath() {
        var inputs = Self.untouched()
        inputs.replayGainDB = -4
        inputs.composedGainDB = -4
        let model = SignalPathModel(inputs)

        #expect(!model.directPath)
        #expect(model.gainActive)
        #expect(model.replayGainText == "-4.0 dB")
        #expect(model.composedGainText == "-4.0 dB")
        // The rate half of the gate is still satisfied — only gain failed.
        #expect(model.sourceRateMatchesDevice)
        #expect(!model.srcActive)
    }

    /// Panning moves the stereo image, which is processing.
    @Test func offCentreBalanceDefeatsTheDirectPath() {
        var inputs = Self.untouched()
        inputs.pan = 0.3
        let model = SignalPathModel(inputs)

        #expect(!model.directPath)
        #expect(model.balanceActive)
        #expect(model.balanceText == "+0.30")
    }

    /// FLAT bands with a −6 dB graphic pre-amp. Band flatness alone would pass this
    /// case; reading the COMPOSED gain is what catches it, and that is the whole
    /// reason the gate is spelled that way.
    @Test func flatBandsWithAGraphicPreampStillDefeatTheDirectPath() {
        var inputs = Self.untouched()
        inputs.composedGainDB = -6
        let model = SignalPathModel(inputs)

        #expect(!model.graphicEQActive, "every band is at 0 dB in this case")
        #expect(model.gainActive)
        #expect(!model.directPath)
        #expect(model.composedGainText == "-6.0 dB")
        #expect(model.replayGainText == "0.0 dB", "the pre-amp is not a ReplayGain trim")
    }

    /// An accepted head-room trim reaches the gate through the same one read.
    @Test func headroomTrimDefeatsTheDirectPath() {
        var inputs = Self.untouched()
        inputs.composedGainDB = -1.5
        let model = SignalPathModel(inputs)

        #expect(!model.directPath)
        #expect(model.composedGainText == "-1.5 dB")
    }

    /// A raised band is processing even at unity gain.
    @Test func aRaisedGraphicBandDefeatsTheDirectPath() {
        var inputs = Self.untouched()
        inputs.graphicBandGains[3] = 3
        let model = SignalPathModel(inputs)

        #expect(model.graphicEQActive)
        #expect(!model.directPath)
    }

    /// An ATTACHED parametric configuration is a node in the chain, even flat.
    @Test func attachedParametricConfigurationDefeatsTheDirectPath() {
        var inputs = Self.untouched()
        inputs.parametricConfiguration = .bypass
        let model = SignalPathModel(inputs)

        #expect(model.parametricEQActive)
        #expect(!model.directPath)
    }

    /// Crossfeed is the fourth optional stage the badge must see.
    @Test func crossfeedDefeatsTheDirectPath() {
        var inputs = Self.untouched()
        inputs.crossfeedEnabled = true
        let model = SignalPathModel(inputs)

        #expect(model.crossfeedActive)
        #expect(!model.directPath)
    }

    /// Unknown is never favourable: with no device rate there is nothing to compare
    /// against, so neither the badge nor the SRC indicator may be claimed.
    @Test func anUnknownDeviceRateClaimsNeitherDirectPathNorConversion() {
        var inputs = Self.untouched()
        inputs.deviceNominalRate = nil
        let model = SignalPathModel(inputs)

        #expect(!model.directPath)
        #expect(!model.srcActive)
        #expect(model.deviceRateText == SignalPathModel.unknownToken)
    }

    /// The same rule from the other side: a file whose tags carry no sample rate.
    @Test func anUnknownSourceRateClaimsNeitherDirectPathNorConversion() {
        var inputs = Self.untouched()
        inputs.sourceSampleRate = nil
        let model = SignalPathModel(inputs)

        #expect(!model.directPath)
        #expect(!model.srcActive)
    }

    /// Nothing known about the source at all: every token degrades to the
    /// placeholder and the summary line is the placeholder too. No crash, no zeros
    /// presented as measurements.
    @Test func absentMetadataRendersPlaceholderTokens() {
        let model = SignalPathModel(SignalPathInputs())

        #expect(model.sourceFormat == SignalPathModel.unknownToken)
        #expect(model.codecToken == SignalPathModel.unknownToken)
        #expect(model.sourceSampleRateToken == SignalPathModel.unknownToken)
        #expect(model.sourceBitDepthToken == SignalPathModel.unknownToken)
        #expect(model.sourceBitrateToken == SignalPathModel.unknownToken)
        #expect(model.connectionFormat == SignalPathModel.unknownToken)
        #expect(model.deviceRateText == SignalPathModel.unknownToken)
        #expect(model.balanceText == "0.00")
        #expect(model.composedGainText == "0.0 dB")
        #expect(!model.directPath)
        #expect(!model.srcActive)
        #expect(!model.isDSD)
    }

    /// A partially-tagged file lists what is known and omits what is not, rather
    /// than padding the line with placeholders.
    @Test func partialMetadataOmitsUnknownComponents() {
        var inputs = SignalPathInputs()
        inputs.codec = "mp3"
        inputs.sourceBitrate = 320_000
        let model = SignalPathModel(inputs)

        #expect(model.sourceFormat == "MP3 · 320 kbps")
        #expect(model.sourceSampleRateToken == SignalPathModel.unknownToken)
    }

    /// DSD is recognised from the container token, so the badge works before — and
    /// after — the DSD playback path lands.
    @Test func dsdContainersRaiseTheDSDBadge() {
        for codec in ["dsf", "DFF", "DSDIFF", "dsd"] {
            var inputs = SignalPathInputs()
            inputs.codec = codec
            #expect(SignalPathModel(inputs).isDSD, "\(codec) should be recognised as DSD")
        }
        var pcm = SignalPathInputs()
        pcm.codec = "FLAC"
        #expect(!SignalPathModel(pcm).isDSD)
    }

    /// Rates are compared with the shared HAL epsilon, so a device reporting
    /// 44100.2 Hz is still "the same rate" and does not fake a conversion.
    @Test func rateComparisonUsesTheSharedDeviceEpsilon() {
        var inputs = Self.untouched()
        inputs.deviceNominalRate = 44100.2
        let model = SignalPathModel(inputs)

        #expect(!model.srcActive)
        #expect(model.directPath)
    }
}

// MARK: - Fixtures

private extension SignalPathModelTests {
    /// 44.1 kHz / 16-bit / stereo FLAC, device at 44.1 kHz, every stage neutral.
    static func untouched() -> SignalPathInputs {
        SignalPathInputs(
            codec: "FLAC",
            sourceSampleRate: 44100,
            sourceBitDepth: 16,
            sourceBitrate: 1_411_000,
            composedGainDB: 0,
            replayGainDB: 0,
            graphicBandGains: [Float](repeating: 0, count: EQBand.allCases.count),
            parametricConfiguration: nil,
            crossfeedEnabled: false,
            pan: 0,
            connectionSampleRate: 44100,
            connectionChannelCount: 2,
            deviceNominalRate: 44100
        )
    }
}
