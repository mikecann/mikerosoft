import Foundation

extension EDLRecipe {
    /// Names of the recipes built into the importer, for `tandem import edl --recipe`.
    public static let builtInNames = ["decision-models"]

    /// A built-in recipe by name, or nil if there's no such recipe.
    public static func builtIn(_ name: String) throws -> EDLRecipe? {
        switch name.lowercased() {
        case "decision-models", "decision models": return try decisionModels
        default: return nil
        }
    }

    /// The recipe for the September 2026 decision-models video, read out of
    /// the Python scripts that built its Filmora projects (build_wfp.py,
    /// fix_cutoffs.py, apply_v6.py, add_gfx.py, add_sfx.py, replace_sfx.py,
    /// assemble.py, replace_music.py, use_originals.py). The notes inside
    /// say where each number came from.
    public static var decisionModels: EDLRecipe {
        get throws {
            try decode(Data(decisionModelsRecipeJSON.utf8), name: "the decision-models recipe")
        }
    }
}

// Kept as JSON rather than Swift values so it reads exactly like a recipe
// file on disk, and so the same decoder that reads those checks it.
private let decisionModelsRecipeJSON = #"""
{
  "name": "Decision Models",
  "root": "~/dev/convex/convex-videos/decision-models",
  "edl": "edit/edl-v2.json",
  "width": 3840,
  "height": 2160,
  "frameRate": 30,
  "takes": [
    {
      "start": 0,
      "camera": "source/main vid/2026-09-24_105434-camera.mov",
      "screen": "source/main vid/2026-09-24_105434-screen.mov"
    },
    {
      "start": 671.396458,
      "camera": "source/main vid/2026-09-24_144426-camera.mov",
      "screen": "source/main vid/2026-09-24_144426-screen.mov"
    },
    {
      "start": 1349.822228,
      "camera": "source/main vid/2026-09-24_145626-camera.mov",
      "screen": "source/main vid/2026-09-24_145626-screen.mov"
    }
  ],
  "voice": {
    "normalizeTo": -28.74
  },
  "pip": {
    "x": 0.8899423480033875,
    "y": 0.8004488348960876,
    "scale": 0.5,
    "cutout": true
  },
  "cameraLook": [
    {
      "type": "hsl",
      "params": {
        "redSaturation": -17,
        "purpleSaturation": -21,
        "blueSaturation": -3
      }
    },
    {
      "type": "vignette",
      "params": {
        "amount": -34
      }
    },
    {
      "type": "colorAdjust",
      "params": {
        "blackLevel": 7
      }
    }
  ],
  "intro": {
    "path": "Intro v5.mp4",
    "replacesBefore": 149.0,
    "normalizeTo": -28.74
  },
  "cutAdjustments": [
    {"start": 149.0, "end": 157.19, "newStart": 149.0, "newEnd": 157.49},
    {"start": 172.486, "end": 178.2, "newStart": 172.486, "newEnd": 178.5},
    {"start": 188.888, "end": 191.989, "newStart": 188.888, "newEnd": 192.32},
    {"start": 192.464, "end": 198.767, "newStart": 192.464, "newEnd": 199.09},
    {"start": 203.042, "end": 206.2, "newStart": 203.042, "newEnd": 206.39},
    {"start": 212.257, "end": 214.962, "newStart": 212.257, "newEnd": 215.02},
    {"start": 232.782, "end": 246.6, "newStart": 232.782, "newEnd": 246.8},
    {"start": 250.127, "end": 252.644, "newStart": 250.127, "newEnd": 252.73},
    {"start": 259.775, "end": 261.6, "newStart": 259.775, "newEnd": 261.74},
    {"start": 290.8, "end": 300.9, "newStart": 290.8, "newEnd": 301.02},
    {"start": 304.5, "end": 312.8, "newStart": 304.5, "newEnd": 313.32},
    {"start": 314.8, "end": 319.0, "newStart": 314.8, "newEnd": 319.31},
    {"start": 323.31, "end": 330.0, "newStart": 323.31, "newEnd": 330.45},
    {"start": 430.6, "end": 438.7, "newStart": 430.6, "newEnd": 438.81},
    {"start": 446.308, "end": 448.767, "newStart": 446.308, "newEnd": 448.8},
    {"start": 448.984, "end": 451.4, "newStart": 448.984, "newEnd": 451.76},
    {"start": 456.361, "end": 458.713, "newStart": 456.361, "newEnd": 458.76},
    {"start": 459.004, "end": 464.3, "newStart": 459.004, "newEnd": 464.81},
    {"start": 480.377, "end": 482.1, "newStart": 480.377, "newEnd": 483.22},
    {"start": 484.7, "end": 494.1, "newStart": 484.7, "newEnd": 494.81},
    {"start": 528.989, "end": 530.412, "newStart": 528.989, "newEnd": 530.46},
    {"start": 530.621, "end": 532.817, "newStart": 530.621, "newEnd": 532.988},
    {"start": 532.988, "end": 536.9, "newStart": 532.988, "newEnd": 537.31},
    {"start": 542.5, "end": 543.901, "newStart": 542.5, "newEnd": 544.089},
    {"start": 544.089, "end": 547.6, "newStart": 544.089, "newEnd": 547.71},
    {"start": 548.5, "end": 551.1, "newStart": 548.5, "newEnd": 551.27},
    {"start": 552.012, "end": 558.6, "newStart": 552.012, "newEnd": 558.77},
    {"start": 560.86, "end": 562.821, "newStart": 560.86, "newEnd": 563.02},
    {"start": 580.678, "end": 588.9, "newStart": 580.678, "newEnd": 589.3},
    {"start": 592.175, "end": 594.4, "newStart": 592.175, "newEnd": 594.85},
    {"start": 636.7, "end": 642.9, "newStart": 636.7, "newEnd": 643.27},
    {"start": 647.5, "end": 652.0, "newStart": 647.5, "newEnd": 652.11},
    {"start": 652.6, "end": 658.127, "newStart": 652.43, "newEnd": 658.127},
    {"start": 660.161, "end": 666.8, "newStart": 660.161, "newEnd": 667.47},
    {"start": 690.8, "end": 706.8, "newStart": 690.8, "newEnd": 707.07},
    {"start": 719.05, "end": 719.511, "newStart": 719.05, "newEnd": 719.94},
    {"start": 725.4, "end": 738.2, "newStart": 725.22, "newEnd": 738.4},
    {"start": 743.321, "end": 750.1, "newStart": 743.23, "newEnd": 750.43},
    {"start": 751.338, "end": 762.6, "newStart": 751.338, "newEnd": 762.82},
    {"start": 778.8, "end": 782.66, "newStart": 778.62, "newEnd": 782.66},
    {"start": 782.793, "end": 790.8, "newStart": 782.793, "newEnd": 791.16},
    {"start": 806.1, "end": 809.8, "newStart": 806.1, "newEnd": 810.07},
    {"start": 812.2, "end": 815.2, "newStart": 812.2, "newEnd": 815.63},
    {"start": 816.0, "end": 823.9, "newStart": 816.0, "newEnd": 824.05},
    {"start": 833.847, "end": 838.068, "newStart": 833.75, "newEnd": 838.068},
    {"start": 838.805, "end": 840.0, "newStart": 838.805, "newEnd": 840.36},
    {"start": 845.8, "end": 851.0, "newStart": 845.8, "newEnd": 851.1},
    {"start": 858.997, "end": 863.1, "newStart": 858.997, "newEnd": 863.23},
    {"start": 864.055, "end": 869.5, "newStart": 864.055, "newEnd": 869.65},
    {"start": 870.386, "end": 872.48, "newStart": 870.386, "newEnd": 872.66},
    {"start": 881.286, "end": 884.419, "newStart": 881.286, "newEnd": 884.69},
    {"start": 886.643, "end": 888.1, "newStart": 886.643, "newEnd": 888.27},
    {"start": 899.611, "end": 901.7, "newStart": 899.611, "newEnd": 901.94},
    {"start": 903.5, "end": 904.5, "newStart": 903.5, "newEnd": 904.55},
    {"start": 905.189, "end": 907.0, "newStart": 905.189, "newEnd": 907.4},
    {"start": 909.172, "end": 910.878, "newStart": 909.172, "newEnd": 911.017},
    {"start": 911.017, "end": 914.6, "newStart": 911.017, "newEnd": 914.68},
    {"start": 991.421, "end": 995.683, "newStart": 991.421, "newEnd": 995.83},
    {"start": 995.915, "end": 997.1, "newStart": 995.915, "newEnd": 997.53},
    {"start": 1003.038, "end": 1027.57, "newStart": 1003.038, "newEnd": 1027.97},
    {"start": 1031.358, "end": 1034.7, "newStart": 1031.358, "newEnd": 1034.81},
    {"start": 1035.7, "end": 1038.2, "newStart": 1035.7, "newEnd": 1038.7},
    {"start": 1038.7, "end": 1044.2, "newStart": 1038.7, "newEnd": 1044.3},
    {"start": 1044.6, "end": 1049.5, "newStart": 1044.6, "newEnd": 1049.85},
    {"start": 1051.269, "end": 1056.183, "newStart": 1051.269, "newEnd": 1056.3},
    {"start": 1058.811, "end": 1062.1, "newStart": 1058.811, "newEnd": 1062.25},
    {"start": 1065.092, "end": 1073.4, "newStart": 1065.092, "newEnd": 1073.88},
    {"start": 1097.3, "end": 1105.732, "newStart": 1097.13, "newEnd": 1106.07},
    {"start": 1106.285, "end": 1136.6, "newStart": 1106.18, "newEnd": 1137.33},
    {"start": 1153.826, "end": 1154.8, "newStart": 1153.826, "newEnd": 1154.98},
    {"start": 1188.1, "end": 1195.6, "newStart": 1188.1, "newEnd": 1195.83},
    {"start": 1205.929, "end": 1207.0, "newStart": 1205.929, "newEnd": 1207.31},
    {"start": 1208.1, "end": 1208.664, "newStart": 1207.96, "newEnd": 1208.848},
    {"start": 1208.848, "end": 1209.998, "newStart": 1208.848, "newEnd": 1210.28},
    {"start": 1212.743, "end": 1219.908, "newStart": 1212.743, "newEnd": 1220.19},
    {"start": 1224.031, "end": 1229.8, "newStart": 1224.031, "newEnd": 1229.88},
    {"start": 1232.16, "end": 1236.4, "newStart": 1232.16, "newEnd": 1236.53},
    {"start": 1278.246, "end": 1281.43, "newStart": 1278.246, "newEnd": 1281.57},
    {"start": 1287.412, "end": 1291.2, "newStart": 1287.412, "newEnd": 1291.25},
    {"start": 1302.3, "end": 1309.6, "newStart": 1302.3, "newEnd": 1309.85},
    {"start": 1316.8, "end": 1321.0, "newStart": 1316.8, "newEnd": 1321.11},
    {"start": 1323.2, "end": 1324.484, "newStart": 1323.2, "newEnd": 1324.84},
    {"start": 1325.77, "end": 1328.6, "newStart": 1325.77, "newEnd": 1328.76},
    {"start": 1351.8, "end": 1353.75, "newStart": 1351.8, "newEnd": 1354.36},
    {"start": 1356.6, "end": 1360.45, "newStart": 1356.29, "newEnd": 1360.57},
    {"start": 1368.905, "end": 1376.7, "newStart": 1368.8, "newEnd": 1376.7},
    {"start": 1381.942, "end": 1387.536, "newStart": 1381.84, "newEnd": 1387.536},
    {"start": 1387.817, "end": 1389.053, "newStart": 1387.7, "newEnd": 1389.053},
    {"start": 1389.278, "end": 1394.3, "newStart": 1389.278, "newEnd": 1394.94},
    {"start": 1397.957, "end": 1400.5, "newStart": 1397.86, "newEnd": 1400.5},
    {"start": 1406.6, "end": 1416.4, "newStart": 1406.48, "newEnd": 1416.95},
    {"start": 1420.5, "end": 1424.5, "newStart": 1420.5, "newEnd": 1425.06},
    {"start": 1434.7, "end": 1438.95, "newStart": 1434.7, "newEnd": 1439.51},
    {"start": 1439.6, "end": 1441.3, "newStart": 1439.6, "newEnd": 1441.63},
    {"start": 1442.1, "end": 1442.788, "newStart": 1441.98, "newEnd": 1443.112},
    {"start": 1443.112, "end": 1443.3, "newStart": 1443.112, "newEnd": 1443.73}
  ],
  "layoutOverrides": [
    {
      "from": 1097.0,
      "to": 1155.1,
      "layout": "screen"
    }
  ],
  "transitions": {
    "layoutSwitch": {
      "type": "cutSlide",
      "duration": 1.04
    },
    "topicPush": {
      "type": "push",
      "direction": "left",
      "duration": 0.8,
      "at": [
        290.8,
        430.6,
        806.1,
        965.0
      ],
      "tolerance": 0.6
    },
    "end": {
      "type": "fadeToBlack",
      "duration": 1.2
    },
    "overlayIn": {
      "type": "push",
      "direction": "down",
      "duration": 0.6
    },
    "overlayOut": {
      "type": "push",
      "direction": "up",
      "duration": 0.8
    }
  },
  "inserts": [
    {
      "path": "motion-graphics/out/clip-02-B.mp4",
      "at": 693.7,
      "duration": 5.0,
      "slideIn": true,
      "slideOut": true,
      "note": "running them all on low reasoning effort"
    },
    {
      "path": "motion-graphics/out/clip-03-C.mp4",
      "at": 714.53,
      "duration": 3.8,
      "slideIn": true,
      "slideOut": true,
      "note": "without any guidelines"
    },
    {
      "path": "motion-graphics/out/clip-07-A.mp4",
      "at": 1210.215,
      "duration": 15.4,
      "slideIn": true,
      "slideOut": true,
      "note": "use cases list"
    },
    {
      "path": "broll/hf-openjev.mp4",
      "at": 1409.892,
      "duration": 4.9,
      "slideIn": true,
      "note": "models on Hugging Face, like OpenJev"
    },
    {
      "path": "broll/hf-laya.mp4",
      "afterPrevious": true,
      "duration": 2.1,
      "note": "Laya"
    },
    {
      "path": "broll/hf-decider.mp4",
      "afterPrevious": true,
      "duration": 4.6,
      "slideOut": true,
      "note": "and Decider 2B"
    }
  ],
  "sections": [
    {
      "name": "Magic Jev Ball",
      "music": "music/intro-1.mp3"
    },
    {
      "name": "Testing decision models",
      "at": 149.0,
      "music": "music/c1a.mp3"
    },
    {
      "name": "What decision models are",
      "at": 290.8,
      "music": "music/c1b.mp3"
    },
    {
      "name": "Decision evals",
      "at": 430.6,
      "music": "music/c1c.mp3"
    },
    {
      "name": "LLMs as decision models",
      "at": 647.5,
      "music": "music/c2.mp3"
    },
    {
      "name": "The new evals site",
      "at": 719.05,
      "music": "music/c3a.mp3"
    },
    {
      "name": "Decision leaderboard",
      "at": 806.1,
      "music": "music/c3b.mp3"
    },
    {
      "name": "Digging into a run",
      "at": 965.0,
      "music": "music/c4.mp3"
    },
    {
      "name": "What Jev is for",
      "at": 1188.1,
      "music": "music/c5.mp3"
    },
    {
      "name": "Outro",
      "music": "music/s6.mp3",
      "outro": true
    }
  ],
  "music": {
    "crossfade": 1.5,
    "normalizeTo": -20,
    "gainDB": -27.73,
    "endFadeOut": 1.6,
    "outroTrim": 0.3
  },
  "sfx": {
    "minGap": 1.5,
    "onTransitions": [
      {
        "on": "layoutSwitch",
        "path": "sfx/swipe.wav",
        "peak": 0.18,
        "gainDB": -22,
        "priority": 2
      },
      {
        "on": "topicPush",
        "path": "sfx/swipe.wav",
        "peak": 0.18,
        "gainDB": -22,
        "priority": 2
      },
      {
        "on": "overlayIn",
        "path": "sfx/in.wav",
        "peak": 0.25,
        "gainDB": -20,
        "priority": 1
      },
      {
        "on": "overlayOut",
        "path": "sfx/out.wav",
        "peak": 0.31,
        "gainDB": -23,
        "priority": 1
      }
    ],
    "events": [
      {
        "path": "~/Library/Application Support/Wondershare Filmora Mac/ProgramData/Download/Filmora/audio/6_Cha_Ching_Cash_Register_04_AISFX_05/Data/Cha Ching Cash Register 04 - AISFX.mp3",
        "at": 914.486,
        "gainDB": -22,
        "note": "180x cheaper"
      }
    ]
  },
  "notes": [
    "Frame rate 30, the footage's own. v14 was a 25 fps Filmora project because build_wfp.py cloned the AI Gateway template.",
    "No audio fades at the camera and screen switches: in v14 those let about half a second of cut-out voice play under the next clip. Voice cuts stay clean.",
    "Takes: the three record-it sessions. EDL time is main-camera.mov, the sessions end to end, so each take starts at its session offset (build_wfp.py CAM_SESSIONS). A session's screen and camera share a clock (use_originals.py, intro.py).",
    "Voice levelled to -28.74 LUFS, the target build_wfp.py gave Filmora's LoudnessGain. level_voice.py's per-clip smoothing needed audio analysis and isn't reproduced.",
    "PiP and camera grade copied from the AI Gateway template clips build_wfp.py cloned: scale 50 at (0.890, 0.800); HSL red -17, purple -21, blue -3; vignette -34; black level +7.",
    "Intro v5.mp4 (intro.py) replaced the Magic Jev Ball segments before take time 149.0, as in Mike's Decision Models.wfp.",
    "Cut adjustments are fix_cutoffs.py's output as saved in Decision Models v5 (tinkerdesk).wfp. Four of them also carry trims Mike made by hand before it ran.",
    "Layout override, transitions and their durations from apply_v6.py; sound rules from replace_sfx.py; the cha-ching from add_sfx.py, just after 'cheaper'.",
    "Graphics from add_gfx.py, with its v7 timeline times turned into take times through Decision Models v7.wfp.",
    "Music: one ElevenLabs cue per section, laid out as assemble.py did (1.5 s crossfades centred on the section cuts, the outro ending with the video), levelled to -20 LUFS like the stitched score, at the -27.73 dB replace_music.py gave it in v14. Beat-alignment offsets weren't recorded, so cues start at 0.",
    "Section names are mine, taken from the transcript at each music boundary."
  ]
}
"""#
