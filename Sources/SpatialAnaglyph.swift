import ArgumentParser
import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

@main struct SpatialAnaglyph: AsyncParsableCommand {
    // MARK: Internal

    @Argument(help: "A spatial video file", transform: URL.init(fileURLWithPath:)) var url: URL

    mutating func run() async throws {
        let asset = AVAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ValidationError("Spatial video has no video track")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)

        let assetReader = try AVAssetReader(asset: asset)
        let output = try await AVAssetReaderTrackOutput(
            track: asset.loadTracks(withMediaType: .video).first!,
            outputSettings: [
                AVVideoDecompressionPropertiesKey: [
                    kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs: [0, 1] as CFArray,
                ],
            ]
        )
        output.alwaysCopiesSampleData = false
        assetReader.add(output)

        let assetWriter = try AVAssetWriter(
            outputURL: url.renamed { "\($0) Anaglyph" },
            fileType: .mov
        )
        let assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoWidthKey: naturalSize.width,
            AVVideoHeightKey: naturalSize.height,
            AVVideoCodecKey: AVVideoCodecType.hevc
        ])
        let assetWriterInputAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: assetWriterInput,
            sourcePixelBufferAttributes: nil
        )
        assetWriterInput.expectsMediaDataInRealTime = false
        assetWriterInput.transform = try await videoTrack.load(.preferredTransform)
        assetWriter.add(assetWriterInput)

        assetReader.startReading()
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: String(describing: Self.self))
            assetWriterInput.requestMediaDataWhenReady(on: queue) {
                while assetWriterInput.isReadyForMoreMediaData {
                    if let nextSampleBuffer = output.copyNextSampleBuffer() {
                        guard let taggedBuffers = nextSampleBuffer.taggedBuffers else { return }

                        let leftEyeBuffer = taggedBuffers.first(where: {
                            $0.tags.first(matchingCategory: .stereoView) == .stereoView(.leftEye)
                        })?.buffer
                        let rightEyeBuffer = taggedBuffers.first(where: {
                            $0.tags.first(matchingCategory: .stereoView) == .stereoView(.rightEye)
                        })?.buffer
                        var outputPixelBuffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(
                            nil,
                            assetWriterInputAdaptor.pixelBufferPool!,
                            &outputPixelBuffer
                        )
                        if let leftEyeBuffer,
                           let rightEyeBuffer,
                           case let .pixelBuffer(leftEyePixelBuffer) = leftEyeBuffer,
                           case let .pixelBuffer(rightEyePixelBuffer) = rightEyeBuffer,
                           let outputPixelBuffer {
                            let leftEye = CIImage(cvPixelBuffer: leftEyePixelBuffer)
                            let rightEye = CIImage(cvPixelBuffer: rightEyePixelBuffer)

                            let filter = AnaglyphFilter()
                            filter.leftImage = leftEye
                            filter.rightImage = rightEye
                            Self.ciContext.render(filter.outputImage!, to: outputPixelBuffer)

                            assetWriterInputAdaptor.append(
                                outputPixelBuffer,
                                withPresentationTime: nextSampleBuffer.presentationTimeStamp
                            )
                        }
                    } else {
                        assetWriterInput.markAsFinished()
                        assetWriter.finishWriting {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        } as Void
    }

    // MARK: Private

    private static let ciContext = CIContext()
}
