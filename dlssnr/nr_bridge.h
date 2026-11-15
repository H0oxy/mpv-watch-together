// DLSS NR (NGX feature 18) for a D3D11 renderer. The runtime only accepts D3D12, so the bridge
// owns a D3D12 device on the same adapter and swaps frames through shared textures and one shared
// fence. Call contract ported from Veyra-NRVideo (GPL-3.0): src/ngx/DlssNrRuntimeAdapter.cpp
// (snippet exports, signed-snippet app id, caller-name shim) and src/pipeline/EnhanceGraph.cpp
// (parameters, zero motion, constant depth 0.5, resource states).
#pragma once
#include <windows.h>
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <string>
#include <vector>
#include <nvsdk_ngx.h>

namespace nr {

inline FILE* g_log = nullptr;
inline void logf(const char* fmt, ...) {
    if (!g_log) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(g_log, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list a; va_start(a, fmt); vfprintf(g_log, fmt, a); va_end(a);
    fputc('\n', g_log); fflush(g_log);
}

// The snippet asks GetModuleFileNameW about its caller and only accepts "nvngx.dll".
// Patched in the snippet's own import table, nowhere else.
using GmfnFn = DWORD(WINAPI*)(HMODULE, LPWSTR, DWORD);
inline GmfnFn g_realGmfn = nullptr;
inline HMODULE g_self = nullptr;
inline DWORD WINAPI ShimGmfn(HMODULE m, LPWSTR out, DWORD size) {
    static const wchar_t name[] = L"nvngx.dll";
    if (m == g_self && g_self) {
        if (size == 0) return 0;
        if (size <= 9) { for (DWORD i = 0; i + 1 < size; ++i) out[i] = name[i]; out[size - 1] = 0; SetLastError(ERROR_INSUFFICIENT_BUFFER); return size; }
        memcpy(out, name, sizeof(name)); return 9;
    }
    return g_realGmfn(m, out, size);
}
inline void** FindImport(HMODULE module, const char* fn) {
    auto* base = (uint8_t*)module;
    auto* nt = (IMAGE_NT_HEADERS*)(base + ((IMAGE_DOS_HEADER*)base)->e_lfanew);
    auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return nullptr;
    for (auto* d = (IMAGE_IMPORT_DESCRIPTOR*)(base + dir.VirtualAddress); d->Name; ++d) {
        const char* dll = (const char*)(base + d->Name);
        if (_stricmp(dll, "kernel32.dll") && _strnicmp(dll, "api-ms-", 7) && _strnicmp(dll, "ext-ms-", 7)) continue;
        auto* look = (ULONGLONG*)(base + (d->OriginalFirstThunk ? d->OriginalFirstThunk : d->FirstThunk));
        auto* iat = (IMAGE_THUNK_DATA*)(base + d->FirstThunk);
        for (size_t i = 0; look[i]; ++i) {
            if (IMAGE_SNAP_BY_ORDINAL64(look[i])) continue;
            if (!strcmp((const char*)((IMAGE_IMPORT_BY_NAME*)(base + (size_t)look[i]))->Name, fn)) return (void**)&iat[i].u1.Function;
        }
    }
    return nullptr;
}

template <class F> __declspec(noinline) NVSDK_NGX_Result guard(F f) {
    __try { return f(); } __except (EXCEPTION_EXECUTE_HANDLER) { logf("SEH 0x%08X", GetExceptionCode()); return NVSDK_NGX_Result_FAIL_PlatformError; }
}

template <class T> void release(T*& p) { if (p) { p->Release(); p = nullptr; } }

struct Settings { float intensity = 1, tone = 1, structure = 1, skin = -1; int style = 0; };

class Bridge {
public:
    Settings s;
    double lastGpuMs = 0; // NR time of the last finished frame, GPU timestamps

    // d11: the renderer's device. dir: folder with nvngx_dlssnr.dll.
    bool init(ID3D11Device* d11, const std::wstring& dir) {
        d11_ = d11;
        if (FAILED(d11->QueryInterface(IID_PPV_ARGS(&d11_5_)))) { logf("ID3D11Device5 unavailable"); return false; }
        IDXGIDevice* xd = nullptr; IDXGIAdapter* xa = nullptr; DXGI_ADAPTER_DESC ad{};
        d11->QueryInterface(IID_PPV_ARGS(&xd)); xd->GetAdapter(&xa); xa->GetDesc(&ad); xa->Release(); xd->Release();
        logf("adapter %ls", ad.Description);
        IDXGIFactory4* f = nullptr; IDXGIAdapter1* a12 = nullptr;
        if (FAILED(CreateDXGIFactory2(0, IID_PPV_ARGS(&f))) || FAILED(f->EnumAdapterByLuid(ad.AdapterLuid, IID_PPV_ARGS(&a12)))) { logf("adapter lookup failed"); return false; }
        f->Release();
        HRESULT hr = D3D12CreateDevice(a12, D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&dev_));
        a12->Release();
        if (FAILED(hr)) { logf("D3D12CreateDevice 0x%08X", (unsigned)hr); return false; }
        D3D12_COMMAND_QUEUE_DESC qd{}; qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        dev_->CreateCommandQueue(&qd, IID_PPV_ARGS(&q_));
        for (auto& al : alloc_) dev_->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&al));
        dev_->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc_[0], nullptr, IID_PPV_ARGS(&list_));
        list_->Close();
        dev_->CreateFence(0, D3D12_FENCE_FLAG_SHARED, IID_PPV_ARGS(&fence_));
        HANDLE fh = nullptr;
        dev_->CreateSharedHandle(fence_, nullptr, GENERIC_ALL, nullptr, &fh);
        hr = d11_5_->OpenSharedFence(fh, IID_PPV_ARGS(&fence11_));
        CloseHandle(fh);
        if (FAILED(hr)) { logf("OpenSharedFence 0x%08X", (unsigned)hr); return false; }
        event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        D3D12_QUERY_HEAP_DESC qh{ D3D12_QUERY_HEAP_TYPE_TIMESTAMP, 2 * kSlots, 0 };
        dev_->CreateQueryHeap(&qh, IID_PPV_ARGS(&queries_));
        readback_ = buffer(D3D12_HEAP_TYPE_READBACK, 16 * kSlots);
        UINT64 freq = 0; q_->GetTimestampFrequency(&freq); tick_ = freq ? 1000.0 / freq : 0;

        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)&ShimGmfn, &g_self);
        LoadLibraryW(L"nvapi64.dll"); // pinned: the runtime's own FreeLibrary must not detach the driver
        wchar_t tmp[MAX_PATH]; GetTempPathW(MAX_PATH, tmp);
        const wchar_t* paths[] = { dir.c_str() };
        NVSDK_NGX_FeatureCommonInfo common{}; common.PathListInfo.Path = paths; common.PathListInfo.Length = 1;
        auto r = guard([&] { return NVSDK_NGX_D3D12_Init_with_ProjectID("7c1d1f0e-5b1a-4f6e-9a57-3d6f2a8b9c41", NVSDK_NGX_ENGINE_TYPE_CUSTOM, "1.0", tmp, dev_, &common, NVSDK_NGX_Version_API); });
        logf("NGX core init 0x%08X", (unsigned)r);
        if (NVSDK_NGX_FAILED(r)) return false;
        r = guard([&] { return NVSDK_NGX_D3D12_AllocateParameters(&params_); });
        if (NVSDK_NGX_FAILED(r) || !params_) { logf("AllocateParameters 0x%08X", (unsigned)r); return false; }

        mod_ = LoadLibraryExW((dir + L"\\nvngx_dlssnr.dll").c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!mod_) { logf("cannot load %ls\\nvngx_dlssnr.dll (%lu)", dir.c_str(), GetLastError()); return false; }
        fInit_ = (InitFn)GetProcAddress(mod_, "NVSDK_NGX_D3D12_Init_Ext");
        fCreate_ = (CreateFn)GetProcAddress(mod_, "NVSDK_NGX_D3D12_CreateFeature");
        fEval_ = (EvalFn)GetProcAddress(mod_, "NVSDK_NGX_D3D12_EvaluateFeature");
        fRelease_ = (ReleaseFn)GetProcAddress(mod_, "NVSDK_NGX_D3D12_ReleaseFeature");
        void** slot = FindImport(mod_, "GetModuleFileNameW");
        if (!fInit_ || !fCreate_ || !fEval_ || !fRelease_ || !slot) { logf("snippet exports/imports missing"); return false; }
        g_realGmfn = (GmfnFn)*slot;
        DWORD old = 0; VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &old);
        InterlockedExchangePointer(slot, (void*)&ShimGmfn);
        VirtualProtect(slot, sizeof(void*), old, &old);
        r = guard([&] { return fInit_(0x0876232Cull, dir.c_str(), dev_, NVSDK_NGX_Version_API, nullptr); });
        logf("NR runtime init 0x%08X", (unsigned)r);
        return ok_ = !NVSDK_NGX_FAILED(r);
    }

    // Runs NR on `frame` in place: an RGBA8 texture of the renderer's device, w x h.
    // Everything is queued on the GPU; the CPU only waits when the D3D12 side is 3 frames behind.
    bool process(ID3D11DeviceContext* c11, ID3D11Texture2D* frame, UINT w, UINT h) {
        if (!ok_ || !resize(w, h)) return false;
        ID3D11DeviceContext4* c4 = nullptr;
        if (FAILED(c11->QueryInterface(IID_PPV_ARGS(&c4)))) return false;
        const UINT slot = UINT(frame_ % kSlots);
        if (frame_ >= kSlots) { wait(2 * (frame_ - kSlots) + 2); readTime(slot); }
        const UINT64 ready = 2 * frame_ + 1, done = 2 * frame_ + 2;
        c11->CopyResource(in11_, frame);
        c4->Signal(fence11_, ready);
        c11->Flush();

        alloc_[slot]->Reset();
        list_->Reset(alloc_[slot], nullptr);
        list_->EndQuery(queries_, D3D12_QUERY_TYPE_TIMESTAMP, 2 * slot);
        barrier(in12_, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        barrier(out12_, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        setFrameParams();
        auto r = guard([&] { return fEval_(list_, handle_, params_, nullptr); });
        barrier(out12_, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COMMON);
        barrier(in12_, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COMMON);
        list_->EndQuery(queries_, D3D12_QUERY_TYPE_TIMESTAMP, 2 * slot + 1);
        list_->ResolveQueryData(queries_, D3D12_QUERY_TYPE_TIMESTAMP, 2 * slot, 2, readback_, 16 * slot);
        list_->Close();
        q_->Wait(fence_, ready);
        // Even after a failed Evaluate the list runs, so the fence advances and the renderer never hangs.
        ID3D12CommandList* lists[] = { list_ };
        q_->ExecuteCommandLists(1, lists);
        q_->Signal(fence_, done);
        c4->Wait(fence11_, done);
        c4->Release();
        ++frame_;
        if (NVSDK_NGX_FAILED(r)) { logf("Evaluate 0x%08X", (unsigned)r); ok_ = false; return false; }
        c11->CopyResource(frame, out11_);
        reset_ = false;
        return true;
    }

    void restartHistory() { reset_ = true; }

    ~Bridge() {
        if (dev_ && frame_) wait(2 * frame_);
        if (handle_) { auto h = handle_; guard([&] { return fRelease_(h); }); }
        // The NGX runtime and core stay loaded until the process exits: unloading mid-session is
        // where community runtimes misbehave, and mpv quits right after this anyway.
    }

private:
    static constexpr UINT kSlots = 3;
    using InitFn = NVSDK_NGX_Result(NVSDK_CONV*)(unsigned long long, const wchar_t*, ID3D12Device*, NVSDK_NGX_Version, const NVSDK_NGX_Parameter*);
    using CreateFn = NVSDK_NGX_Result(NVSDK_CONV*)(ID3D12GraphicsCommandList*, NVSDK_NGX_Feature, NVSDK_NGX_Parameter*, NVSDK_NGX_Handle**);
    using EvalFn = NVSDK_NGX_Result(NVSDK_CONV*)(ID3D12GraphicsCommandList*, const NVSDK_NGX_Handle*, const NVSDK_NGX_Parameter*, PFN_NVSDK_NGX_ProgressCallback);
    using ReleaseFn = NVSDK_NGX_Result(NVSDK_CONV*)(NVSDK_NGX_Handle*);

    ID3D11Device* d11_ = nullptr; ID3D11Device5* d11_5_ = nullptr; ID3D11Fence* fence11_ = nullptr;
    ID3D12Device* dev_ = nullptr; ID3D12CommandQueue* q_ = nullptr; ID3D12GraphicsCommandList* list_ = nullptr;
    ID3D12CommandAllocator* alloc_[kSlots]{}; ID3D12Fence* fence_ = nullptr; HANDLE event_ = nullptr;
    ID3D12QueryHeap* queries_ = nullptr; ID3D12Resource* readback_ = nullptr; double tick_ = 0;
    ID3D12Resource *in12_ = nullptr, *out12_ = nullptr, *mvec_ = nullptr, *depth_ = nullptr;
    ID3D11Texture2D *in11_ = nullptr, *out11_ = nullptr;
    HMODULE mod_ = nullptr; InitFn fInit_ = nullptr; CreateFn fCreate_ = nullptr; EvalFn fEval_ = nullptr; ReleaseFn fRelease_ = nullptr;
    NVSDK_NGX_Parameter* params_ = nullptr; NVSDK_NGX_Handle* handle_ = nullptr;
    UINT w_ = 0, h_ = 0; UINT64 frame_ = 0; bool ok_ = false, reset_ = true;

    static NVSDK_NGX_Result NVSDK_CONV ratioCb(NVSDK_NGX_Parameter* p) { if (p) p->Set("DLSSNR.ScalingRatio", 1.0f); return NVSDK_NGX_Result_Success; }

    void wait(UINT64 v) {
        if (fence_->GetCompletedValue() >= v) return;
        fence_->SetEventOnCompletion(v, event_);
        WaitForSingleObject(event_, 2000);
    }
    void readTime(UINT slot) {
        UINT64* t = nullptr; D3D12_RANGE rr{ 16 * slot, 16 * slot + 16 };
        if (SUCCEEDED(readback_->Map(0, &rr, (void**)&t))) { lastGpuMs = (t[2 * slot + 1] - t[2 * slot]) * tick_; D3D12_RANGE none{ 0, 0 }; readback_->Unmap(0, &none); }
    }
    void barrier(ID3D12Resource* r, D3D12_RESOURCE_STATES a, D3D12_RESOURCE_STATES b) {
        D3D12_RESOURCE_BARRIER br{}; br.Transition.pResource = r; br.Transition.StateBefore = a; br.Transition.StateAfter = b;
        br.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        list_->ResourceBarrier(1, &br);
    }
    ID3D12Resource* buffer(D3D12_HEAP_TYPE type, UINT64 size) {
        D3D12_HEAP_PROPERTIES hp{ type }; D3D12_RESOURCE_DESC rd{};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; rd.Width = size; rd.Height = 1; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
        rd.SampleDesc.Count = 1; rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ID3D12Resource* r = nullptr;
        dev_->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, type == D3D12_HEAP_TYPE_UPLOAD ? D3D12_RESOURCE_STATE_GENERIC_READ : D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&r));
        return r;
    }
    ID3D12Resource* texture(DXGI_FORMAT f, bool shared, ID3D11Texture2D** open11) {
        ID3D12Resource* r = nullptr;
        HRESULT hr;
        if (shared) {
            // D3D11 creates, D3D12 opens: D3D11 refuses to open D3D12-created textures (E_INVALIDARG).
            D3D11_TEXTURE2D_DESC td{}; td.Width = w_; td.Height = h_; td.MipLevels = 1; td.ArraySize = 1; td.Format = f;
            td.SampleDesc.Count = 1; td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_RENDER_TARGET;
            td.MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
            hr = d11_->CreateTexture2D(&td, nullptr, open11);
            if (FAILED(hr)) { logf("shared CreateTexture2D 0x%08X", (unsigned)hr); return nullptr; }
            IDXGIResource1* xr = nullptr; HANDLE h = nullptr;
            (*open11)->QueryInterface(IID_PPV_ARGS(&xr));
            hr = xr->CreateSharedHandle(nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, nullptr, &h);
            xr->Release();
            if (SUCCEEDED(hr)) { hr = dev_->OpenSharedHandle(h, IID_PPV_ARGS(&r)); CloseHandle(h); }
            if (FAILED(hr)) { logf("share to D3D12 0x%08X", (unsigned)hr); release(*open11); return nullptr; }
            return r;
        }
        D3D12_HEAP_PROPERTIES hp{ D3D12_HEAP_TYPE_DEFAULT }; D3D12_RESOURCE_DESC rd{};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; rd.Width = w_; rd.Height = h_; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
        rd.Format = f; rd.SampleDesc.Count = 1;
        hr = dev_->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&r));
        if (FAILED(hr)) { logf("CreateCommittedResource 0x%08X", (unsigned)hr); return nullptr; }
        return r;
    }
    // Uploads one constant 4-byte texel everywhere and leaves the texture as a shader resource.
    bool fill(ID3D12Resource* t, DXGI_FORMAT f, uint32_t texel) {
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{}; UINT64 total = 0;
        D3D12_RESOURCE_DESC rd = t->GetDesc();
        dev_->GetCopyableFootprints(&rd, 0, 1, 0, &fp, nullptr, nullptr, &total);
        ID3D12Resource* up = buffer(D3D12_HEAP_TYPE_UPLOAD, total);
        uint8_t* p = nullptr; up->Map(0, nullptr, (void**)&p);
        for (UINT y = 0; y < h_; ++y) for (UINT x = 0; x < w_; ++x) memcpy(p + y * fp.Footprint.RowPitch + 4 * x, &texel, 4);
        up->Unmap(0, nullptr);
        D3D12_TEXTURE_COPY_LOCATION dst{ t, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX }, src{ up, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT };
        dst.SubresourceIndex = 0; src.PlacedFootprint = fp; (void)f;
        barrier(t, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_DEST);
        list_->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
        barrier(t, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        pendingUploads_.push_back(up);
        return true;
    }
    std::vector<ID3D12Resource*> pendingUploads_;

    bool resize(UINT w, UINT h) {
        if (handle_ && w == w_ && h == h_) return true;
        if (frame_) wait(2 * frame_);
        if (handle_) { auto hh = handle_; guard([&] { return fRelease_(hh); }); handle_ = nullptr; }
        release(in11_); release(out11_); release(in12_); release(out12_); release(mvec_); release(depth_);
        w_ = w; h_ = h; reset_ = true;
        in12_ = texture(DXGI_FORMAT_R8G8B8A8_UNORM, true, &in11_);
        out12_ = texture(DXGI_FORMAT_R8G8B8A8_UNORM, true, &out11_);
        mvec_ = texture(DXGI_FORMAT_R16G16_FLOAT, false, nullptr);
        depth_ = texture(DXGI_FORMAT_R32_FLOAT, false, nullptr);
        if (!in12_ || !out12_ || !mvec_ || !depth_) { ok_ = false; return false; }

        auto* p = params_;
        for (const char* n : { "DLSSNR.Width", "DLSSNR.InputWidth", "DLSSNR.OutputWidth", "DLSSNR.Output.Width", "Width" }) p->Set(n, (unsigned)w);
        for (const char* n : { "DLSSNR.Height", "DLSSNR.InputHeight", "DLSSNR.OutputHeight", "DLSSNR.Output.Height", "Height" }) p->Set(n, (unsigned)h);
        p->Set("DLSSNR.Upscaling", 0u); p->Set("DLSSNR.Scale", 1.0f); p->Set("DLSSNR.ScalingRatio", 1.0f);
        p->Set("DLSSNRComputeScalingRatioCallback", (void*)&ratioCb);
        p->Set("DLSSNR.Hint.Render.Preset", 0); p->Set("PerfQualityValue", 1);
        p->Set("CreationNodeMask", 1u); p->Set("VisibilityNodeMask", 1u);

        alloc_[0]->Reset(); list_->Reset(alloc_[0], nullptr);
        fill(mvec_, DXGI_FORMAT_R16G16_FLOAT, 0);
        const float half = 0.5f; uint32_t bits; memcpy(&bits, &half, 4);
        fill(depth_, DXGI_FORMAT_R32_FLOAT, bits);
        auto r = guard([&] { return fCreate_(list_, (NVSDK_NGX_Feature)18, params_, &handle_); });
        list_->Close();
        ID3D12CommandList* lists[] = { list_ };
        q_->ExecuteCommandLists(1, lists);
        // The init list gets its own fence value pair so the frame numbering stays even/odd.
        q_->Signal(fence_, 2 * frame_ + 2); wait(2 * frame_ + 2); ++frame_;
        for (auto* u : pendingUploads_) u->Release();
        pendingUploads_.clear();
        logf("NR feature %ux%u: 0x%08X", w, h, (unsigned)r);
        if (NVSDK_NGX_FAILED(r) || !handle_) { handle_ = nullptr; ok_ = false; return false; }
        return true;
    }

    void setFrameParams() {
        auto* p = params_;
        p->Set("DLSSNR.Color", in12_); p->Set("DLSSNR.Output", out12_);
        p->Set("DLSSNR.MVec", mvec_); p->Set("DLSSNR.Depth", depth_);
        for (const char* n : { "DLSSNR.ColorSubrectWidth", "DLSSNR.OutputSubrectWidth", "DLSSNR.MVecSubrectWidth", "DLSSNR.DepthSubrectWidth" }) p->Set(n, (unsigned)w_);
        for (const char* n : { "DLSSNR.ColorSubrectHeight", "DLSSNR.OutputSubrectHeight", "DLSSNR.MVecSubrectHeight", "DLSSNR.DepthSubrectHeight" }) p->Set(n, (unsigned)h_);
        p->Set("DLSSNR.MVecScaleX", 1.0f); p->Set("DLSSNR.MVecScaleY", 1.0f);
        p->Set("DLSSNR.DepthInverted", 1);
        p->Set("DLSS.Indicator.Invert.X.Axis", 0); p->Set("DLSS.Indicator.Invert.Y.Axis", 0);
        p->Set("DLSSNR.Enabled", 1); p->Set("DLSSNR.Reset", reset_ ? 1 : 0);
        p->Set("DLSSNR.Style", s.style); p->Set("DLSSNR.Intensity", s.intensity);
        p->Set("DLSSNR.LocalToneStrength", s.tone); p->Set("DLSSNR.LocalStructureStrength", s.structure);
        p->Set("DLSSNR.SkinStructureStrength", s.skin);
        p->Set("DLSSNR.UseAutoMask", 0); p->Set("DLSSNR.UICorrection", 0);
    }
};

} // namespace nr
