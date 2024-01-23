import CoreImage

class AnaglyphFilter: CIFilter {
    static var kernel: CIKernel = try! CIColorKernel.kernels(withMetalString: """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[ stitchable ]] float4 anaglyph(coreimage::sample_t leftImage, coreimage::sample_t rightImage) {
            return float4(leftImage.r, rightImage.g, rightImage.b, 1);
        }
    """)[0]

    var leftImage: CIImage?
    var rightImage: CIImage?

    override var outputImage: CIImage? {
        Self.kernel.apply(
            extent: leftImage!.extent,
            roiCallback: { _, rect in rect },
            arguments: [leftImage!, rightImage!]
        )
    }
}
