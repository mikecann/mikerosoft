import XCTest
@testable import TandemCore
@testable import TandemMedia

final class AnalysisNeedsTests: XCTestCase {
    func t(_ s: Double) -> Time { Time(seconds: s) }

    /// A folder's worth of media, only some of it on the timeline.
    func project() -> Project {
        var p = Project.standard(name: "Needs")
        p.media = [
            MediaItem(id: "med_cam", path: "source/a-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_scr", path: "source/a-screen.mov", kind: .video, role: .screen, duration: t(600), width: 3200, height: 1800, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_old", path: "Video v12.mp4", kind: .video, role: .other, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_cam2", path: "source/b-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_bed", path: "music/bed.mp3", kind: .audio, role: .music, duration: t(120), hasAudio: true)
        ]
        let camera = p.location(ofTrack: p.track(named: "Camera")!.id)!
        let screen = p.location(ofTrack: p.track(named: "Screen")!.id)!
        let voice = p.location(ofTrack: p.track(named: "Voice")!.id)!
        var cam = Clip(id: "clip_cam", content: .media(mediaID: "med_cam"), start: .zero, duration: t(10))
        cam.video = VideoProperties(cutout: Cutout(enabled: true, mode: .personAndProps))
        p[camera].clips = [cam]
        p[screen].clips = [Clip(id: "clip_scr", content: .media(mediaID: "med_scr"), start: .zero, duration: t(10))]
        var sound = Clip(id: "clip_voice", content: .media(mediaID: "med_scr"), start: .zero, duration: t(10))
        sound.audio = AudioProperties(voiceIsolation: 0.5)
        p[voice].clips = [sound]
        return p
    }

    func kinds(_ needs: [AnalysisNeeds.Need], _ id: String) -> Set<AnalysisKind> {
        Set(needs.filter { $0.mediaID == id }.map(\.kind))
    }

    func testHeavyWorkOnlyForWhatTheEditUses() {
        let needs = AnalysisNeeds.needs(for: project())
        // On the timeline with its cutout on: everything it needs.
        XCTAssertEqual(kinds(needs, "med_cam"), [.thumbnails, .waveform, .loudness, .transcript, .proxy, .matte])
        // Screen on the Voice track with isolation: transcript and isolated
        // voice, a proxy, but no matte.
        XCTAssertEqual(kinds(needs, "med_scr"), [.thumbnails, .waveform, .loudness, .transcript, .proxy, .isolatedVoice])
        // An old render in the folder: only the cheap ones.
        XCTAssertEqual(kinds(needs, "med_old"), [.thumbnails, .waveform, .loudness])
        // A camera take not placed yet: searchable, nothing heavy.
        XCTAssertEqual(kinds(needs, "med_cam2"), [.thumbnails, .waveform, .loudness, .transcript])
        XCTAssertEqual(needs.first { $0.mediaID == "med_cam2" }?.priority, .background)
        XCTAssertEqual(kinds(needs, "med_bed"), [.waveform, .loudness])
    }

    func testFilesMacOSCantDecodeAreConvertedFirst() {
        var p = project()
        p.media += [
            MediaItem(id: "med_pop", path: "stickers/pop.mov", kind: .video, role: .sticker, duration: t(2), width: 512, height: 512, hasVideo: true, hasAlpha: true, undecodableCodec: "rle "),
            MediaItem(id: "med_spare", path: "stickers/spare.mov", kind: .video, role: .sticker, duration: t(2), width: 512, height: 512, hasVideo: true, hasAlpha: true, undecodableCodec: "png ")
        ]
        let graphics = p.location(ofTrack: p.track(named: "Graphics")!.id)!
        p[graphics].clips = [Clip(id: "clip_pop", content: .media(mediaID: "med_pop"), start: .zero, duration: t(2))]
        let needs = AnalysisNeeds.needs(for: p)

        let placed = needs.filter { $0.mediaID == "med_pop" }
        XCTAssertEqual(placed.map(\.kind), [.converted, .thumbnails])
        XCTAssertEqual(placed.first?.priority, .timeline)
        // Not on the timeline yet: converted in the background so the
        // browser can show it.
        let spare = needs.filter { $0.mediaID == "med_spare" }
        XCTAssertEqual(spare.map(\.kind), [.converted, .thumbnails])
        XCTAssertEqual(spare.first?.priority, .background)
        XCTAssertFalse(kinds(needs, "med_cam").contains(.converted))

        XCTAssertEqual(MediaAnalysis.defaultKinds(for: p.media.first { $0.id == "med_pop" }!), [.converted, .thumbnails])
    }

    func testMatteFollowsTheCutoutMode() {
        var p = project()
        let camera = p.location(ofTrack: p.track(named: "Camera")!.id)!
        var plain = Clip(id: "clip_cam_b", content: .media(mediaID: "med_cam"), start: t(20), duration: t(5))
        plain.video = VideoProperties(cutout: Cutout(enabled: true, mode: .person))
        p[camera].clips.append(plain)
        let mattes = AnalysisNeeds.needs(for: p).filter { $0.kind == .matte }
        XCTAssertEqual(Set(mattes.compactMap(\.matteMode)), [.person, .personAndProps])
    }

    func testCutoutOffMeansNoMatte() {
        var p = project()
        let camera = p.location(ofTrack: p.track(named: "Camera")!.id)!
        p[camera].clips[0].video?.cutout?.enabled = false
        XCTAssertFalse(kinds(AnalysisNeeds.needs(for: p), "med_cam").contains(.matte))
    }
}
