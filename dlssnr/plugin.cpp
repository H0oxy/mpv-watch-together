// mpv C plugin: runs every presented frame through DLSS NR (nr_bridge.h).
// mpv has no hook into its renderer, so this patches IDXGISwapChain::Present/Present1 in the shared
// DXGI vtable: the finished frame (video, subtitles, OSD) is processed in place right before Present.
// Needs --gpu-api=d3d11 (mpv's default on Windows) and --d3d11-output-format=rgba8.
// Menu, keys and OSD text live in dlssnr-menu.lua. This side takes script-messages
//   dlssnr-toggle | dlssnr-style <0..2> | dlssnr-intensity <0..1>
// and publishes user-data/dlssnr/{enabled,style,intensity,status,info}.
// Options (--script-opts): dlssnr-dir=<folder with nvngx_dlssnr.dll> (default: this DLL's folder),
// dlssnr-intensity=<0..1, default 1>, dlssnr-style=<0..2>, dlssnr-start=yes|no.
#include "nr_bridge.h"
#include <mpv/client.h>
#include <atomic>
#include <mutex>

namespace {

std::atomic<bool> g_enabled{ true };
std::atomic<bool> g_reset{ false };
std::atomic<int> g_style{ 0 };
std::atomic<float> g_intensity{ 1.0f };
std::atomic<double> g_gpuMs{ 0 };
std::atomic<UINT> g_w{ 0 }, g_h{ 0 };
std::wstring g_dir;
std::mutex g_statusLock;
// Set by the render thread, published by the plugin thread:
// starting | on | error-init | error-format <dxgi format> | error-device | error-process
std::string g_status = "starting";

nr::Bridge* g_bridge = nullptr; // render thread only; never freed, see ~Bridge
ID3D11Device* g_device = nullptr;
bool g_dead = false;

void setStatus(const std::string& s) { std::lock_guard<std::mutex> l(g_statusLock); g_status = s; nr::logf("status: %s", s.c_str()); }

using PresentFn = HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain*, UINT, UINT);
using Present1Fn = HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain1*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*);
PresentFn g_realPresent = nullptr;
Present1Fn g_realPresent1 = nullptr;
thread_local bool t_inside = false;

void onPresent(IDXGISwapChain* sc, UINT flags) {
    if (t_inside || (flags & DXGI_PRESENT_TEST) || !g_enabled || g_dead) return;
    t_inside = true;
    ID3D11Device* dev = nullptr;
    ID3D11Texture2D* bb = nullptr;
    ID3D11DeviceContext* ctx = nullptr;
    if (SUCCEEDED(sc->GetDevice(IID_PPV_ARGS(&dev))) && SUCCEEDED(sc->GetBuffer(0, IID_PPV_ARGS(&bb)))) {
        D3D11_TEXTURE2D_DESC d{}; bb->GetDesc(&d);
        if (!g_bridge) {
            g_bridge = new nr::Bridge;
            g_device = dev; dev->AddRef();
            if (!g_bridge->init(dev, g_dir)) { g_dead = true; setStatus("error-init"); }
            else setStatus("on");
        }
        if (g_dead) {
        } else if (dev != g_device) {
            g_dead = true; setStatus("error-device");
        } else if (d.Format != DXGI_FORMAT_R8G8B8A8_UNORM && d.Format != DXGI_FORMAT_R8G8B8A8_UNORM_SRGB) {
            g_dead = true; setStatus("error-format " + std::to_string(d.Format));
        } else {
            dev->GetImmediateContext(&ctx);
            g_bridge->s.style = g_style; g_bridge->s.intensity = g_intensity;
            if (g_reset.exchange(false)) g_bridge->restartHistory();
            if (!g_bridge->process(ctx, bb, d.Width, d.Height)) { g_dead = true; setStatus("error-process"); }
            g_gpuMs = g_bridge->lastGpuMs; g_w = d.Width; g_h = d.Height;
        }
    }
    nr::release(ctx); nr::release(bb); nr::release(dev);
    t_inside = false;
}

HRESULT STDMETHODCALLTYPE HookPresent(IDXGISwapChain* sc, UINT sync, UINT flags) { onPresent(sc, flags); return g_realPresent(sc, sync, flags); }
HRESULT STDMETHODCALLTYPE HookPresent1(IDXGISwapChain1* sc, UINT sync, UINT flags, const DXGI_PRESENT_PARAMETERS* p) { onPresent(sc, flags); return g_realPresent1(sc, sync, flags, p); }

bool patch(void** slot, void* hook, void** real) {
    DWORD old = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &old)) return false;
    *real = InterlockedExchangePointer(slot, hook);
    VirtualProtect(slot, sizeof(void*), old, &old);
    return true;
}

// All flip-model D3D11 swap chains in the process share DXGI's vtable, so patching it through a
// throwaway swap chain also covers the one mpv creates later.
bool installHooks() {
    WNDCLASSW wc{}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"dlssnr-probe";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW, 0, 0, 8, 8, nullptr, nullptr, wc.hInstance, nullptr);
    ID3D11Device* dev = nullptr; IDXGIFactory2* f = nullptr; IDXGISwapChain1* sc = nullptr;
    bool ok = false;
    if (hwnd && SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &dev, nullptr, nullptr)) &&
        SUCCEEDED(CreateDXGIFactory2(0, IID_PPV_ARGS(&f)))) {
        DXGI_SWAP_CHAIN_DESC1 d{}; d.Width = 8; d.Height = 8; d.Format = DXGI_FORMAT_R8G8B8A8_UNORM; d.SampleDesc.Count = 1;
        d.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; d.BufferCount = 2; d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        if (SUCCEEDED(f->CreateSwapChainForHwnd(dev, hwnd, &d, nullptr, nullptr, &sc))) {
            void** vt = *(void***)sc;
            ok = patch(&vt[8], (void*)&HookPresent, (void**)&g_realPresent) && patch(&vt[22], (void*)&HookPresent1, (void**)&g_realPresent1);
            nr::logf("hooks %s, vtable %p", ok ? "installed" : "FAILED", (void*)vt);
        }
    }
    nr::release(sc); nr::release(f); nr::release(dev);
    if (hwnd) DestroyWindow(hwnd);
    return ok;
}

std::string opt(mpv_handle* h, const char* key, const char* def) {
    std::string v = def;
    mpv_node n{};
    if (mpv_get_property(h, "script-opts", MPV_FORMAT_NODE, &n) >= 0) {
        if (n.format == MPV_FORMAT_NODE_MAP)
            for (int i = 0; i < n.u.list->num; ++i)
                if (!strcmp(n.u.list->keys[i], key) && n.u.list->values[i].format == MPV_FORMAT_STRING) v = n.u.list->values[i].u.string;
        mpv_free_node_contents(&n);
    }
    return v;
}

std::wstring widen(const std::string& s) {
    std::wstring w(MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), (int)w.size());
    w.resize(wcslen(w.c_str()));
    return w;
}

float clampIntensity(double v) { return v < 0 ? 0.0f : v > 1 ? 1.0f : (float)v; }

void put(mpv_handle* h, const char* name, const std::string& value) {
    mpv_set_property_string(h, (std::string("user-data/dlssnr/") + name).c_str(), value.c_str());
}

void publishSettings(mpv_handle* h) {
    char b[16];
    put(h, "enabled", g_enabled ? "yes" : "no");
    put(h, "style", std::to_string(g_style.load()));
    snprintf(b, sizeof b, "%.2f", g_intensity.load());
    put(h, "intensity", b);
}

} // namespace

extern "C" __declspec(dllexport) int mpv_open_cplugin(mpv_handle* h) {
    wchar_t path[MAX_PATH]; GetTempPathW(MAX_PATH, path);
    nr::g_log = _wfopen((std::wstring(path) + L"dlssnr.log").c_str(), L"w");
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)&mpv_open_cplugin, &self);
    GetModuleFileNameW(self, path, MAX_PATH);
    *wcsrchr(path, L'\\') = 0;
    g_dir = widen(opt(h, "dlssnr-dir", ""));
    if (g_dir.empty()) g_dir = path;
    g_style = atoi(opt(h, "dlssnr-style", "0").c_str()) % 3;
    g_intensity = clampIntensity(atof(opt(h, "dlssnr-intensity", "1").c_str()));
    g_enabled = opt(h, "dlssnr-start", "yes") != "no";
    nr::logf("dlssnr plugin, runtime dir %ls", g_dir.c_str());
    publishSettings(h);
    if (!installHooks()) { put(h, "status", "error-hook"); return 0; }
    put(h, "status", g_enabled ? "starting" : "off");

    std::string shown = "starting";
    ULONGLONG lastInfo = 0;
    for (;;) {
        mpv_event* e = mpv_wait_event(h, 0.25);
        if (e->event_id == MPV_EVENT_SHUTDOWN) break;
        if (e->event_id == MPV_EVENT_PLAYBACK_RESTART || e->event_id == MPV_EVENT_FILE_LOADED) g_reset = true;
        if (e->event_id == MPV_EVENT_CLIENT_MESSAGE) {
            auto* m = (mpv_event_client_message*)e->data;
            if (m->num_args < 1) continue;
            const std::string cmd = m->args[0];
            if (cmd == "dlssnr-toggle") g_enabled = !g_enabled;
            else if (cmd == "dlssnr-style" && m->num_args > 1) g_style = atoi(m->args[1]) % 3;
            else if (cmd == "dlssnr-intensity" && m->num_args > 1) g_intensity = clampIntensity(atof(m->args[1]));
            else continue;
            g_reset = true;
            publishSettings(h);
            nr::logf("settings: enabled=%d style=%d intensity=%.2f", (int)g_enabled, g_style.load(), g_intensity.load());
        }
        std::string s;
        { std::lock_guard<std::mutex> l(g_statusLock); s = g_status; }
        if (s != shown) { shown = s; put(h, "status", s); }
        if (GetTickCount64() - lastInfo > 1000) { // read on demand by the menu script, nobody observes it
            lastInfo = GetTickCount64();
            char b[64];
            snprintf(b, sizeof b, "%ux%u %.1f", g_w.load(), g_h.load(), g_gpuMs.load());
            put(h, "info", b);
        }
    }
    g_enabled = false; // the hook stays in DXGI's vtable until exit and passes frames through from now on
    nr::logf("plugin thread exit");
    return 0;
}
