#if canImport(CoreAI)
import CoreAI
import Foundation

/// A stud keypoint detector on Core AI (ADR 0020, Proposed). A skeleton: no
/// model is trained, nothing constructs this, and no setting reaches it.
/// It exists so the shape the roadmap's Core AI traps demand is fixed
/// before a model is:
/// - **Loaded on opt-in, never mid-build.** Specialization can take minutes
///   and its cache is purged by every OS update, so `prepare()` runs behind
///   explanatory UI, not on first use.
/// - **One run in flight.** Concurrent runs each allocate their own scratch
///   memory with no cap; this actor serialises them.
/// - **Strides from the descriptor.** An input not laid out to
///   `NDArrayDescriptor.preferredStrides` costs a layout copy on every run,
///   silently; a dynamic shape must be resolved before those strides are
///   read, or it is a programming error.
/// - **AOT for h18p.** `coreai-build` exits 0 for any architecture; the
///   shipped asset must be compiled for the 17 Pro's.
///
/// Core AI is absent from the Simulator SDK and from Xcode 16.4, so CI
/// type-checks this file against the iOS 27 device SDK only.
@available(iOS 27, macOS 27, *)
actor CoreAIStudKeypointDetector: StudKeypointDetecting {
    enum DetectorError: Error {
        case missingFunction(String)
        case unexpectedInput(String)
        case missingOutput(String)
    }

    static let functionName = "main"
    static let inputName = "image"
    static let outputName = "heatmap"

    private let modelURL: URL
    private var function: InferenceFunction?

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    /// Specializes and loads the model. Call when the person turns the
    /// detector on, never during a build.
    func prepare() async throws {
        guard function == nil else { return }
        let model = try await AIModel(contentsOf: modelURL)
        guard let loaded = try model.loadFunction(named: Self.functionName) else {
            throw DetectorError.missingFunction(Self.functionName)
        }
        function = loaded
    }

    func heatmap(rgb: [UInt8], width: Int, height: Int) async throws -> StudHeatmap? {
        guard let function else { return nil }
        guard case .ndArray(let declared)? = function.descriptor.inputDescriptor(of: Self.inputName) else {
            throw DetectorError.unexpectedInput(Self.inputName)
        }
        // Planar float16 RGB, [1, 3, height, width], normalised to [0, 1].
        let descriptor = declared.hasDynamicShape
            ? declared.resolvingDynamicDimensions([1, 3, height, width])
            : declared
        guard descriptor.shape == [1, 3, height, width], descriptor.scalarType == .float16 else {
            throw DetectorError.unexpectedInput("\(descriptor.shape) \(descriptor.scalarType)")
        }
        let strides = descriptor.preferredStrides
        var input = NDArray(shape: descriptor.shape, scalarType: .float16, strides: strides)
        let view = input.mutableView(as: Float16.self)
        view.withUnsafeMutablePointer { pointer, _, _ in
            for y in 0..<height {
                for x in 0..<width {
                    for channel in 0..<3 {
                        let offset = channel * strides[1] + y * strides[2] + x * strides[3]
                        pointer[offset] = Float16(Float(rgb[(y * width + x) * 3 + channel]) / 255)
                    }
                }
            }
        }
        var outputs = try await function.run(inputs: [Self.inputName: input])
        guard let output = outputs.remove(Self.outputName)?.ndArray else {
            throw DetectorError.missingOutput(Self.outputName)
        }
        // [1, 1, h, w] float16 likelihoods.
        let shape = output.shape
        guard shape.count == 4, shape[0] == 1, shape[1] == 1 else {
            throw DetectorError.missingOutput("\(Self.outputName) has shape \(shape)")
        }
        let outputStrides = output.strides
        var values = [Float](repeating: 0, count: shape[2] * shape[3])
        output.view(as: Float16.self).withUnsafePointer { pointer, _, _ in
            for y in 0..<shape[2] {
                for x in 0..<shape[3] {
                    values[y * shape[3] + x] = Float(pointer[y * outputStrides[2] + x * outputStrides[3]])
                }
            }
        }
        return StudHeatmap(values: values, width: shape[3], height: shape[2], scale: Float(width) / Float(shape[3]))
    }
}
#endif
