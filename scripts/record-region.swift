// Records a screen region for the demo masters (docs/DEVELOPMENT.md "演示视频"): everything on
// screen inside the rect (Allume's window and the companion's panel above it), at the display's
// pixel density, up to 60 fps, without the pointer, as ProRes 422 HQ. ScreenCaptureKit only
// delivers a frame when the picture changed, so the file is variable frame rate; the masters
// are made constant 60 fps afterwards (make-demo-media.sh).
//
// Build: swiftc -O scripts/record-region.swift -o build/record-region
// Usage: build/record-region <x,y,w,h> <seconds> <out.mov>
//   x,y,w,h in global points, top-left origin (as CGWindowListCopyWindowInfo gives window bounds).
// Needs Screen Recording permission for the app it runs under.
import AVFoundation
import AppKit
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: record-region <x,y,w,h> <seconds> <out.mov>\n".utf8)); exit(2)
}
let n = args[1].split(separator: ",").compactMap { Double($0) }
guard n.count == 4, let seconds = Double(args[2]) else { exit(2) }
let rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
let out = URL(fileURLWithPath: args[3])
try? FileManager.default.removeItem(at: out)

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sample.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData, input.append(sample) { frames += 1 }
    }
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
            FileHandle.standardError.write(Data("no display under \(rect)\n".utf8)); exit(1)
        }
        let scale = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY,
                                   width: rect.width, height: rect.height)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        let recorder = try Recorder(url: out, width: config.width, height: config.height)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        recorder.input.markAsFinished()
        await recorder.writer.finishWriting()
        print("\(recorder.frames) frames, \(config.width)×\(config.height) → \(out.path)")
        exit(recorder.writer.status == .completed ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("record-region: \(error.localizedDescription)\n".utf8)); exit(1)
    }
}
RunLoop.main.run()
