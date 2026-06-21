#import "DLCapture.h"
#include "DeckLinkAPI.h"
#include <atomic>

@interface DLCapture ()
- (void)deliverFrame:(IDeckLinkVideoInputFrame *)frame;
- (void)formatChanged:(IDeckLinkDisplayMode *)mode flags:(BMDDetectedVideoInputFormatFlags)sigFlags;
@end

// ---- C++ IDeckLinkInputCallback, forwards to the owning DLCapture ----
class InputCallback : public IDeckLinkInputCallback {
public:
    InputCallback(DLCapture *owner) : m_ref(1), m_owner(owner) {}
    virtual ~InputCallback() = default;

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (ppv == nullptr) return E_POINTER;
        CFUUIDBytes unknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &unknown, sizeof(REFIID)) == 0) { *ppv = this; AddRef(); return S_OK; }
        if (memcmp(&iid, &IID_IDeckLinkInputCallback, sizeof(REFIID)) == 0) {
            *ppv = static_cast<IDeckLinkInputCallback *>(this); AddRef(); return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++m_ref; }
    ULONG Release() override { ULONG c = --m_ref; if (c == 0) delete this; return c; }

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents,
                                    IDeckLinkDisplayMode *newMode,
                                    BMDDetectedVideoInputFormatFlags flags) override {
        @autoreleasepool { if (newMode) [m_owner formatChanged:newMode flags:flags]; }
        return S_OK;
    }
    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *frame,
                                   IDeckLinkAudioInputPacket *) override {
        @autoreleasepool { if (frame) [m_owner deliverFrame:frame]; }
        return S_OK;
    }

private:
    std::atomic<ULONG>             m_ref;
    __unsafe_unretained DLCapture *m_owner;
};

@implementation DLCapture {
    IDeckLink      *_deckLink;
    IDeckLinkInput *_input;
    InputCallback  *_cb;
    BOOL            _formatDetect;
    BOOL            _capturing;
    BMDPixelFormat  _pixelFormat;
    NSLock         *_cbLock;     // serialises capture-thread callbacks vs teardown
}

+ (NSArray<NSString *> *)deviceNames {
    NSMutableArray *names = [NSMutableArray array];
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return names;
    IDeckLink *dl = nullptr;
    while (it->Next(&dl) == S_OK) {
        CFStringRef cf = nullptr;
        if (dl->GetDisplayName(&cf) == S_OK && cf) {
            [names addObject:(__bridge_transfer NSString *)cf];
        } else {
            [names addObject:@"DeckLink device"];
        }
        dl->Release();
    }
    it->Release();
    return names;
}

- (instancetype)initWithDeviceIndex:(int)index {
    self = [super init];
    if (!self) return nil;

    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return nil;
    IDeckLink *dl = nullptr, *chosen = nullptr;
    int idx = 0;
    while (it->Next(&dl) == S_OK) {
        if (idx == index) { chosen = dl; break; }
        dl->Release();
        idx++;
    }
    it->Release();
    if (!chosen) return nil;
    _deckLink = chosen;

    if (_deckLink->QueryInterface(IID_IDeckLinkInput, (void **)&_input) != S_OK || !_input)
        return nil;

    // does this input support automatic format detection?
    IDeckLinkProfileAttributes *attr = nullptr;
    if (_deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attr) == S_OK && attr) {
        bool flag = false;
        if (attr->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &flag) == S_OK)
            _formatDetect = flag ? YES : NO;
        attr->Release();
    }

    _cbLock = [[NSLock alloc] init];
    _cb = new InputCallback(self);
    _pixelFormat = bmdFormat10BitYUV;
    return self;
}

- (void)start {
    if (!_input || _capturing) return;
    _input->SetCallback(_cb);

    BMDVideoInputFlags flags = _formatDetect ? bmdVideoInputEnableFormatDetection
                                             : bmdVideoInputFlagDefault;

    // pick the first input display mode as the starting point; format detection
    // will switch to the actual incoming signal
    BMDDisplayMode startMode = bmdModeHD1080i5994;
    IDeckLinkDisplayModeIterator *mit = nullptr;
    if (_input->GetDisplayModeIterator(&mit) == S_OK && mit) {
        IDeckLinkDisplayMode *m = nullptr;
        if (mit->Next(&m) == S_OK && m) { startMode = m->GetDisplayMode(); m->Release(); }
        mit->Release();
    }

    if (_input->EnableVideoInput(startMode, _pixelFormat, flags) != S_OK) {
        [self emitFormat:@"DeckLink · unable to enable input"];
        return;
    }
    if (_input->StartStreams() != S_OK) {
        [self emitFormat:@"DeckLink · unable to start (device in use?)"];
        return;
    }
    _capturing = YES;
    [self emitFormat:@"DeckLink · waiting for signal…"];
}

- (void)stop {
    // mark inactive under the lock so any in-flight callback either finishes
    // (we wait for it) or bails; StopStreams then drains the capture thread
    [_cbLock lock];
    BOOL wasCapturing = _capturing;
    _capturing = NO;
    [_cbLock unlock];
    if (_input && wasCapturing) {
        _input->StopStreams();
        _input->SetCallback(nullptr);
        _input->DisableVideoInput();
    }
}

- (void)dealloc {
    [self stop];
    if (_input)   { _input->Release();   _input = nullptr; }
    if (_deckLink){ _deckLink->Release(); _deckLink = nullptr; }
    if (_cb)      { _cb->Release();      _cb = nullptr; }
}

// ---- callbacks from the DeckLink capture thread ----

- (void)formatChanged:(IDeckLinkDisplayMode *)mode flags:(BMDDetectedVideoInputFormatFlags)sigFlags {
    [_cbLock lock];
    BOOL active = _capturing && _input != nullptr && mode != nullptr;
    [_cbLock unlock];
    if (!active) return;

    BMDPixelFormat pf = (sigFlags & bmdDetectedVideoInput8BitDepth) ? bmdFormat8BitYUV : bmdFormat10BitYUV;
    BMDVideoInputFlags flags = _formatDetect ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault;

    _input->StopStreams();
    if (_input->EnableVideoInput(mode->GetDisplayMode(), pf, flags) != S_OK) {
        [self emitFormat:@"DeckLink · unable to apply detected mode"];
        return;
    }
    if (_input->StartStreams() != S_OK) {
        [self emitFormat:@"DeckLink · unable to restart capture"];
        return;
    }
    _pixelFormat = pf;

    long w = mode->GetWidth(), h = mode->GetHeight();
    CFStringRef name = nullptr;
    mode->GetName(&name);
    NSString *nm = name ? (__bridge_transfer NSString *)name : @"";
    NSString *fmt = (pf == bmdFormat10BitYUV) ? @"v210 10-bit" : @"8-bit YUV";
    [self emitFormat:[NSString stringWithFormat:@"DeckLink · %ld×%ld · %@ · %@", w, h, fmt, nm]];
}

- (void)deliverFrame:(IDeckLinkVideoInputFrame *)frame {
    [_cbLock lock];
    if (!_capturing) { [_cbLock unlock]; return; }

    if (frame->GetFlags() & bmdFrameHasNoInputSource) {
        [_cbLock unlock];
        [self emitFormat:@"DeckLink · no input signal"];
        return;
    }
    BMDPixelFormat pf = frame->GetPixelFormat();
    if (pf != bmdFormat10BitYUV && pf != bmdFormat8BitYUV) { [_cbLock unlock]; return; }

    long w = frame->GetWidth(), h = frame->GetHeight(), rb = frame->GetRowBytes();

    // SDK 16: pixel bytes are accessed through IDeckLinkVideoBuffer.
    // StartAccess / EndAccess must be paired independently of GetBytes.
    IDeckLinkVideoBuffer *vbuf = nullptr;
    if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&vbuf) == S_OK && vbuf) {
        if (vbuf->StartAccess(bmdBufferAccessRead) == S_OK) {
            void *bytes = nullptr;
            if (vbuf->GetBytes(&bytes) == S_OK && bytes) {
                BOOL isV210 = (pf == bmdFormat10BitYUV);
                int matrix = (h >= 2160) ? 2 : (h >= 720 ? 1 : 0);
                DLFrameHandler handler = self.frameHandler;
                if (handler) handler((int)w, (int)h, (int)rb, isV210, bytes, (int)(rb * h), matrix, 0);
            }
            vbuf->EndAccess(bmdBufferAccessRead);
        }
        vbuf->Release();
    }
    [_cbLock unlock];
}

- (void)emitFormat:(NSString *)s {
    void (^h)(NSString *) = self.formatHandler;
    if (h) dispatch_async(dispatch_get_main_queue(), ^{ h(s); });
}

@end
