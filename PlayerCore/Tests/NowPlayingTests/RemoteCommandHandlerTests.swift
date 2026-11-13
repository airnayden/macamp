import Foundation
@testable import Services
import Testing

@MainActor
struct RemoteCommandHandlerTests {
    @Test("play / pause / toggle commands go through the coordinator")
    func transportCommands() {
        let spy = SpyCoordinator()
        let handler = RemoteCommandHandler(coordinator: spy)
        #expect(handler.handlePlay() == .success)
        #expect(handler.handlePause() == .success)
        #expect(handler.handleTogglePlayPause() == .success)
        #expect(spy.commands == [.play, .pause, .toggle])
    }

    @Test("next / previous commands go through the coordinator")
    func skipCommands() {
        let spy = SpyCoordinator()
        let handler = RemoteCommandHandler(coordinator: spy)
        handler.handleNextTrack()
        handler.handlePreviousTrack()
        #expect(spy.commands == [.next, .previous])
    }

    @Test("seek command forwards the requested position")
    func seekCommand() {
        let spy = SpyCoordinator()
        let handler = RemoteCommandHandler(coordinator: spy)
        #expect(handler.handleSeek(to: 42.5) == .success)
        #expect(spy.commands == [.seek(42.5)])
    }

    @Test("seek rejects an invalid position without touching the coordinator")
    func seekRejectsInvalid() {
        let spy = SpyCoordinator()
        let handler = RemoteCommandHandler(coordinator: spy)
        #expect(handler.handleSeek(to: -1) == .commandFailed)
        #expect(handler.handleSeek(to: .infinity) == .commandFailed)
        #expect(spy.commands.isEmpty)
    }

    @Test("every command routes through the coordinator, never the engine")
    func allCommandsRouteThroughCoordinator() {
        let spy = SpyCoordinator()
        let handler = RemoteCommandHandler(coordinator: spy)
        handler.handlePlay()
        handler.handlePause()
        handler.handleTogglePlayPause()
        handler.handleNextTrack()
        handler.handlePreviousTrack()
        handler.handleSeek(to: 5)
        #expect(spy.commands == [.play, .pause, .toggle, .next, .previous, .seek(5)])
    }
}
