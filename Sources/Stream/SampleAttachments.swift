import CoreMedia

extension CMSampleBuffer {
    /// Sets a boolean sample attachment, such as `kCMSampleAttachmentKey_DisplayImmediately`, to true.
    func setAttachment(_ key: CFString) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0
        else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
