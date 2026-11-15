// Self-check of the bridge outside mpv: D3D11 device like mpv's, one RGBA frame through DLSS NR.
// nrtest <dll dir> <in.rgba> <w> <h> <out.rgba> [frames]
#include "nr_bridge.h"

int wmain(int argc, wchar_t** argv) {
    if (argc < 6) { puts("usage: nrtest <dll dir> <in.rgba> <w> <h> <out.rgba> [frames]"); return 2; }
    nr::g_log = stdout;
    const UINT w = _wtoi(argv[3]), h = _wtoi(argv[4]);
    const int frames = argc > 6 ? _wtoi(argv[6]) : 8;
    std::vector<uint8_t> px((size_t)w * h * 4);
    FILE* f = _wfopen(argv[2], L"rb");
    if (!f || fread(px.data(), 1, px.size(), f) != px.size()) { puts("cannot read input"); return 1; }
    fclose(f);

    ID3D11Device* dev = nullptr; ID3D11DeviceContext* ctx = nullptr;
    D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_1;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &fl, 1, D3D11_SDK_VERSION, &dev, nullptr, &ctx))) { puts("no d3d11"); return 1; }
    D3D11_TEXTURE2D_DESC td{}; td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1; td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ID3D11Texture2D* frame = nullptr;
    dev->CreateTexture2D(&td, nullptr, &frame);

    nr::Bridge b;
    if (!b.init(dev, argv[1])) return 1;
    for (int i = 0; i < frames; ++i) {
        ctx->UpdateSubresource(frame, 0, nullptr, px.data(), w * 4, 0); // same source each time, like a paused video
        if (!b.process(ctx, frame, w, h)) return 1;
        printf("frame %d ok, NR gpu %.2f ms (value from 3 frames ago)\n", i, b.lastGpuMs);
    }
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D* st = nullptr; dev->CreateTexture2D(&td, nullptr, &st);
    ctx->CopyResource(st, frame);
    D3D11_MAPPED_SUBRESOURCE m{};
    if (FAILED(ctx->Map(st, 0, D3D11_MAP_READ, 0, &m))) { puts("map failed"); return 1; }
    f = _wfopen(argv[5], L"wb");
    size_t diff = 0; long long sum = 0;
    for (UINT y = 0; y < h; ++y) {
        const uint8_t* row = (const uint8_t*)m.pData + (size_t)y * m.RowPitch;
        fwrite(row, 1, (size_t)w * 4, f);
        for (UINT x = 0; x < w * 4; ++x) { int d = row[x] - px[(size_t)y * w * 4 + x]; diff += d != 0; sum += d < 0 ? -d : d; }
    }
    fclose(f);
    printf("RESULT %zu of %zu bytes changed, mean abs diff %.2f\n", diff, px.size(), double(sum) / px.size());
    return diff ? 0 : 3; // 3: NR ran but left the frame untouched
}
