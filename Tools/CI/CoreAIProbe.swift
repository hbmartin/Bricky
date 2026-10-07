// Type-checked by CI beside the Core AI stud keypoint seam (ADR 0020). The
// seam lives under `#if canImport(CoreAI)`, and an SDK without Core AI (the
// Simulator's, Xcode 16.4's) would compile it to nothing and pass; this
// makes that loud instead.
#if !canImport(CoreAI)
#error("this SDK has no Core AI: the stud keypoint seam would compile to nothing")
#endif
