import XCTest
@testable import TandemAPI
@testable import TandemCore

final class TimelineDumpTests: XCTestCase {
    /// Every kind of clip and setting the dump knows how to show.
    static func kitchenSink() -> Project {
        var project = Project(id: "prj_sink", name: "Sink", settings: ProjectSettings(width: 1920, height: 1080, frameRate: .fps25))
        project.media = [
            MediaItem(id: "med_a", path: "source/a-camera.mov", kind: .video, role: .camera, duration: t(100), frameRate: .fps25, width: 1920, height: 1080, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_b", path: "other/a-camera.mov", kind: .video, role: .broll, duration: t(100), hasVideo: true),
            MediaItem(id: "med_logo", path: "graphics/logo.png", kind: .image, role: .image, hasVideo: true)
        ]
        var zoomed = Clip(id: "clip_zoom", content: .media(mediaID: "med_a"), start: t(12), duration: t(4), sourceStart: t(20), speed: 2, enabled: false)
        zoomed.keyframes = ["video.transform.scale": [Keyframe(time: .zero, value: .number(1))], "video.opacity": [Keyframe(time: .zero, value: .number(1))]]
        zoomed.video = VideoProperties(transform: Transform(position: Point(x: 0.25, y: 0.5), scale: 1.5, rotation: -5), crop: Crop(left: 0.25, right: 0.25), opacity: 0.8, effects: [Effect(id: "fx_b", type: "blur", enabled: false)])
        project.videoTracks = [
            Track(id: "trk_v1", kind: .video, name: "Screen", clips: [
                Clip(id: "clip_one", content: .media(mediaID: "med_a"), start: t(2), duration: t(8), sourceStart: t(2)),
                zoomed,
                Clip(id: "clip_frz", content: .media(mediaID: "med_a"), start: t(16), duration: t(2), sourceStart: t(40), freezeFrame: true)
            ], transitions: [
                Transition(id: "tr_in", type: .fadeFromBlack, duration: t(1), fromClipID: nil, toClipID: "clip_one"),
                Transition(id: "tr_out", type: .push, direction: .left, duration: t(0.7), fromClipID: "clip_frz", toClipID: nil)
            ], locked: true, rippleMode: .cut),
            Track(id: "trk_v2", kind: .video, name: "Overlays", clips: [
                Clip(id: "clip_other", name: "Server room", content: .media(mediaID: "med_b"), start: t(0), duration: t(3)),
                Clip(id: "clip_logo", content: .media(mediaID: "med_logo"), start: t(3), duration: t(2), tags: ["agent:claude"]),
                Clip(id: "clip_black", content: .solid(color: RGBA(r: 0, g: 0, b: 0, a: 0.5)), start: t(5), duration: t(1)),
                Clip(id: "clip_adj", content: .adjustment, start: t(6), duration: t(1), video: VideoProperties(effects: [Effect(id: "fx_c", type: "colorAdjust")])),
                Clip(id: "clip_chart", content: .graphic(GraphicContent(template: "remotion:BarChart")), start: t(7), duration: t(2)),
                Clip(id: "clip_title", content: .text(TextContent(text: "A very long title that goes on\nand on well past the limit", animationOut: "fadeOut")), start: t(9), duration: t(1))
            ], hidden: true, targeted: false, rippleMode: .off)
        ]
        project.audioTracks = [
            Track(id: "trk_a1", kind: .audio, name: "Voice", clips: [
                Clip(id: "clip_voice", content: .media(mediaID: "med_a"), start: t(2), duration: t(8), sourceStart: t(2),
                     audio: AudioProperties(gainDB: 2.5, fadeIn: t(0.25), muted: true, voiceIsolation: 0.4, effects: [Effect(id: "fx_p", type: "pitchShift")]))
            ], muted: true, solo: true, rippleMode: .cut)
        ]
        project.markers = [Marker(id: "mk_todo", time: t(4), duration: t(2), name: "Fix audio", kind: .todo, note: "hum")]
        return project
    }

    func testFixtureSnapshot() {
        let expected = """
        Decision Models: 01:00.000 long, 3840x2160 at 30 fps, revision 7
        Tracks top to bottom as the app shows them. cut tracks hold the take and ripple edits cut them together; follow tracks move with them; off tracks stay put.
        Clips: ID, start-end on the timeline, length, content [source in-out of the file], then settings that aren't the defaults.

        Markers
          00:30.000  section  "Section 2"  mk_s2

        V5 Text  trk_text  follow
          clip_txt1  00:02.000-00:05.000     3.000s  text "DECISION MODELS" callout  in popIn

        V4 Graphics  trk_graphics  follow
          (empty)

        V3 B-roll  trk_broll  follow
          clip_brl1  00:20.000-00:25.000     5.000s  servers.mp4 [00:01.000-00:06.000]

        V2 Camera  trk_camera  cut
          clip_cam1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  layout pipRight  scale 0.5 at 0.87,0.77  cutout  fx dropShadow
            ~ dissolve 0.500s into clip_cam2  tr_dissolve
          clip_cam2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  layout pipRight  scale 0.5 at 0.87,0.77  cutout  fx dropShadow

        V1 Screen  trk_screen  cut
          clip_scr1  00:00.000-00:30.000    30.000s  take1-screen.mov [00:00.500-00:30.500]  linked #1
          clip_scr2  00:30.000-01:00.000    30.000s  take1-screen.mov [00:32.500-01:02.500]  linked #2

        A1 Voice  trk_voice  cut
          clip_voc1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  level -14 LUFS
          clip_voc2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  level -14 LUFS

        A2 Music  trk_music  follow
          clip_mus1  00:00.000-01:00.000  01:00.000  bed.m4a [00:00.000-01:00.000]  gain -31 dB  fade out 2.000s

        A3 SFX  trk_sfx  follow
          (empty)

        Media
          med_broll   broll/servers.mp4  broll  00:10.000  1920x1080 30fps
          med_camera  source/take1-camera.mov  camera  01:10.000  3840x2160 30fps  take take1 +0.500s
          med_screen  source/take1-screen.mov  screen  01:11.000  3840x2160 30fps  take take1 +0.000s
          med_music   music/bed.m4a  music  03:00.000

        """
        assertSameText(TimelineDump.render(APIFixture.project(), revision: 7), expected)
    }

    func testRangeWithWordsSnapshot() {
        let analysis = FakeAnalysis()
        let options = TimelineDump.Options(from: t(29), to: t(31), transcripts: { analysis.transcript(for: $0) })
        let text = TimelineDump.render(APIFixture.project(), options: options)
        let expected = """
        Decision Models: 01:00.000 long, 3840x2160 at 30 fps
        Showing 00:29.000 to 00:31.000: clips that overlap it, at their full length.
        Tracks top to bottom as the app shows them. cut tracks hold the take and ripple edits cut them together; follow tracks move with them; off tracks stay put.
        Clips: ID, start-end on the timeline, length, content [source in-out of the file], then settings that aren't the defaults.

        Markers
          00:30.000  section  "Section 2"  mk_s2

        V5 Text  trk_text  follow
          (nothing here in this range)

        V4 Graphics  trk_graphics  follow
          (nothing here in this range)

        V3 B-roll  trk_broll  follow
          (nothing here in this range)

        V2 Camera  trk_camera  cut
          clip_cam1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  layout pipRight  scale 0.5 at 0.87,0.77  cutout  fx dropShadow
            ~ dissolve 0.500s into clip_cam2  tr_dissolve
          clip_cam2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  layout pipRight  scale 0.5 at 0.87,0.77  cutout  fx dropShadow

        V1 Screen  trk_screen  cut
          clip_scr1  00:00.000-00:30.000    30.000s  take1-screen.mov [00:00.500-00:30.500]  linked #1
          clip_scr2  00:30.000-01:00.000    30.000s  take1-screen.mov [00:32.500-01:02.500]  linked #2

        A1 Voice  trk_voice  cut
          clip_voc1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  level -14 LUFS
              "...Second section."
          clip_voc2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  level -14 LUFS
              "Now let's..."

        A2 Music  trk_music  follow
          clip_mus1  00:00.000-01:00.000  01:00.000  bed.m4a [00:00.000-01:00.000]  gain -31 dB  fade out 2.000s

        A3 SFX  trk_sfx  follow
          (nothing here in this range)

        Media
          med_camera  source/take1-camera.mov  camera  01:10.000  3840x2160 30fps  take take1 +0.500s
          med_screen  source/take1-screen.mov  screen  01:11.000  3840x2160 30fps  take take1 +0.000s
          med_music   music/bed.m4a  music  03:00.000

        """
        assertSameText(text, expected)
    }

    func testKitchenSinkSnapshot() {
        let expected = """
        Sink: 00:18.000 long, 1920x1080 at 25 fps
        Tracks top to bottom as the app shows them. cut tracks hold the take and ripple edits cut them together; follow tracks move with them; off tracks stay put.
        Clips: ID, start-end on the timeline, length, content [source in-out of the file], then settings that aren't the defaults.

        Markers
          00:04.000-00:06.000  todo  "Fix audio" (hum)  mk_todo

        V2 Overlays  trk_v2  off hidden untargeted
          clip_other  00:00.000-00:03.000  3.000s  other/a-camera.mov [00:00.000-00:03.000]  named "Server room"
          clip_logo   00:03.000-00:05.000  2.000s  logo.png  #agent:claude
          clip_black  00:05.000-00:06.000  1.000s  solid #000000 at 0.5
          clip_adj    00:06.000-00:07.000  1.000s  adjustment  fx colorAdjust
          clip_chart  00:07.000-00:09.000  2.000s  graphic remotion:BarChart
          clip_title  00:09.000-00:10.000  1.000s  text "A very long title that goes on / and on well ..."  out fadeOut

        V1 Screen  trk_v1  cut locked
            gap 00:00.000-00:02.000 (2.000s)
            ~ fadeFromBlack 1.000s in  tr_in
          clip_one    00:02.000-00:10.000  8.000s  source/a-camera.mov [00:02.000-00:10.000]
            gap 00:10.000-00:12.000 (2.000s)
          clip_zoom   00:12.000-00:16.000  4.000s  source/a-camera.mov [00:20.000-00:28.000]  disabled  speed 2x  scale 1.5 at 0.25,0.5  rotated -5  crop l0.25 r0.25  opacity 0.8  fx blur(off)  animates opacity,scale
          clip_frz    00:16.000-00:18.000  2.000s  source/a-camera.mov frozen at 00:40.000
            ~ push left 0.700s out  tr_out

        A1 Voice  trk_a1  cut muted solo
            gap 00:00.000-00:02.000 (2.000s)
          clip_voice  00:02.000-00:10.000  8.000s  source/a-camera.mov [00:02.000-00:10.000]  muted  gain 2.5 dB  fade in 0.250s  isolate voice 0.4  fx pitchShift

        Media
          med_b     other/a-camera.mov  broll  01:40.000
          med_logo  graphics/logo.png  image
          med_a     source/a-camera.mov  camera  01:40.000  1920x1080 25fps

        """
        assertSameText(TimelineDump.render(Self.kitchenSink()), expected)
    }

    func testMissingTranscriptsAreNotedOnce() {
        let options = TimelineDump.Options(transcripts: { _ in nil })
        let text = TimelineDump.render(APIFixture.project(), options: options)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[3], "No transcript yet for med_camera, so its clips show no words.")
        XCTAssertEqual(lines.filter { $0.contains("No transcript") }.count, 1)
    }

    func assertSameText(_ actual: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard actual != expected else { return }
        let a = actual.components(separatedBy: "\n")
        let e = expected.components(separatedBy: "\n")
        for index in 0..<max(a.count, e.count) {
            let left = index < a.count ? a[index] : "<none>"
            let right = index < e.count ? e[index] : "<none>"
            if left != right {
                XCTFail("line \(index + 1) differs:\n  got:      \(left)\n  expected: \(right)", file: file, line: line)
                return
            }
        }
    }
}
