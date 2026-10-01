// vboard: mock FPGA board. Runs the placed-and-routed design (Verilator) behind an SDL2 front panel.
//   LEDs, 4 buttons, 8 switches, 4-digit multiplexed 7-seg, 640x480 VGA, UART TX -> terminal.
//   Keys: 0-7 toggle switches | A S D F hold btn0-3 | mouse works too | Esc quits.
// Headless:  vboard --cycles N [--sw 0x07] [--btn 0x1] [--shot out.bmp] [--vcd out.vcd]
#include <SDL.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include "Vpcb.h"
#include "verilated.h"
#ifdef WITH_VCD
#include "verilated_vcd_c.h"
#endif

using Clock = std::chrono::steady_clock;
static constexpr double   CLK_HZ = 25e6;
static constexpr int      WIN_W = 960, WIN_H = 520, VW = 640, VH = 480, PX = 690;
static constexpr int      BIT_CYCLES = 217;              // 25 MHz / 115200 baud

static Vpcb*   dut;
static uint8_t btn_key, btn_mouse, sw_state;
static uint64_t cyc;
#ifdef WITH_VCD
static VerilatedVcdC* tfp;
#endif

// ---- sampled peripherals --------------------------------------------------
static uint32_t fb[VW * VH];
static int      hx, vy, phs = 1, pvs = 1;
static uint64_t led_on[8], seg_on[4][7];
static double   led_v[8], seg_v[4][7];
static int      u_state = 2, u_cnt, u_bit, u_byte;   // 2 = wait for idle-high first (floating pin != start bit)

static uint8_t  p_led, p_seg, p_dig;
static uint64_t t_last, frame0;
static void flush() {             // account the pin values held since the last change
    uint64_t n = cyc - t_last; t_last = cyc;
    if (!n) return;
    for (int i = 0; i < 8; i++) led_on[i] += (uint64_t)((p_led >> i) & 1) * n;
    for (int d = 0; d < 4; d++)
        if ((p_dig >> d) & 1) for (int s = 0; s < 7; s++) seg_on[d][s] += (uint64_t)((p_seg >> s) & 1) * n;
}
static void reset_acc() { flush(); memset(led_on, 0, sizeof led_on); memset(seg_on, 0, sizeof seg_on); frame0 = cyc; }

static void sample() {
    uint8_t led = dut->led, seg = dut->seg, dig = dut->dig;
    if (led != p_led || seg != p_seg || dig != p_dig) { flush(); p_led = led; p_seg = seg; p_dig = dig; }

    // VGA: assume standard 640x480@60 timing, one pixel per clock, sync active-low.
    int hs = dut->vga_hs, vs = dut->vga_vs;
    bool hfall = phs && !hs, vfall = pvs && !vs;
    if (vfall) vy = 0; else if (hfall) vy++;
    if (hfall) hx = 0; else hx++;
    phs = hs; pvs = vs;
    int px = hx - 144, py = vy - 34;                     // sync + back porch
    if ((unsigned)px < VW && (unsigned)py < VH)
        fb[py * VW + px] = 0xFF000000u | ((dut->vga_r & 15) * 17u) << 16
                                       | ((dut->vga_g & 15) * 17u) << 8 | ((dut->vga_b & 15) * 17u);

    // UART TX, 8N1
    int tx = dut->uart_tx;
    if (u_state == 0) { if (!tx) { u_state = 1; u_cnt = BIT_CYCLES * 3 / 2; u_bit = 0; u_byte = 0; } }
    else if (u_state == 1) {
        if (--u_cnt == 0) {
            u_byte |= tx << u_bit; u_cnt = BIT_CYCLES;
            if (++u_bit == 8) { putchar(u_byte); fflush(stdout); u_state = 2; }
        }
    } else if (tx) u_state = 0;
}

static void tick() {
    dut->clk = 0; dut->eval();
#ifdef WITH_VCD
    if (tfp) tfp->dump(2 * cyc);
#endif
    sample();
    dut->clk = 1; dut->eval();
#ifdef WITH_VCD
    if (tfp) tfp->dump(2 * cyc + 1);
#endif
    cyc++;
}

static void finish_frame(bool snap = false) {   // on-time counters -> (smoothed) brightness
    flush(); uint64_t nsamp = cyc - frame0; frame0 = cyc;
    if (!nsamp) return;
    const double a = snap ? 1.0 : 0.5;
    for (int i = 0; i < 8; i++) { led_v[i] = (1 - a) * led_v[i] + a * (double)led_on[i] / nsamp; led_on[i] = 0; }
    for (int d = 0; d < 4; d++) for (int s = 0; s < 7; s++) {
        double v = std::fmin(1.0, 3.0 * seg_on[d][s] / (double)nsamp);   // mux duty -> perceived brightness
        seg_v[d][s] = (1 - a) * seg_v[d][s] + a * v; seg_on[d][s] = 0;
    }
}

// ---- drawing ----------------------------------------------------------------
struct R { int x, y, w, h; };
static R btn_r(int i) { return { PX + (3 - i) * 62, 120, 50, 50 }; }
static R sw_r(int i)  { return { PX + (7 - i) * 31, 215, 25, 56 }; }
static R dig_r(int d) { return { PX + (3 - d) * 62, 340, 50, 90 }; }
static bool hit(R r, int x, int y) { return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h; }

static void col(SDL_Renderer* r, int R_, int G, int B) { SDL_SetRenderDrawColor(r, R_, G, B, 255); }
static void fill(SDL_Renderer* r, R q) { SDL_Rect s{q.x, q.y, q.w, q.h}; SDL_RenderFillRect(r, &s); }
static void mix(SDL_Renderer* r, const int a[3], const int b[3], double v) {
    col(r, a[0] + (int)((b[0] - a[0]) * v), a[1] + (int)((b[1] - a[1]) * v), a[2] + (int)((b[2] - a[2]) * v));
}
static void disc(SDL_Renderer* r, int cx, int cy, int rad) {
    for (int dy = -rad; dy <= rad; dy++) {
        int dx = (int)std::sqrt((double)(rad * rad - dy * dy));
        SDL_RenderDrawLine(r, cx - dx, cy + dy, cx + dx, cy + dy);
    }
}
static void seg7(SDL_Renderer* r, R q, const double v[7], const int off[3], const int on[3]) {
    int t = q.w / 6, vh = (q.h - 3 * t) / 2;
    R s[7] = { {q.x + t, q.y, q.w - 2 * t, t},            {q.x + q.w - t, q.y + t, t, vh},
               {q.x + q.w - t, q.y + 2 * t + vh, t, vh},  {q.x + t, q.y + q.h - t, q.w - 2 * t, t},
               {q.x, q.y + 2 * t + vh, t, vh},            {q.x, q.y + t, t, vh},
               {q.x + t, q.y + t + vh, q.w - 2 * t, t} };
    for (int i = 0; i < 7; i++) { mix(r, off, on, v[i]); fill(r, s[i]); }
}
static void label(SDL_Renderer* r, int n, int cx, int y) {   // tiny digit silkscreen
    static const uint8_t m[10] = {0x3F,0x06,0x5B,0x4F,0x66,0x6D,0x7D,0x07,0x7F,0x6F};
    double v[7]; for (int i = 0; i < 7; i++) v[i] = (m[n] >> i) & 1;
    const int off[3] = {16, 92, 56}, on[3] = {235, 235, 235};
    seg7(r, {cx - 5, y, 10, 16}, v, off, on);
}

static void render(SDL_Renderer* r, SDL_Texture* tex) {
    col(r, 16, 92, 56); SDL_RenderClear(r);                              // PCB
    col(r, 0, 0, 0); fill(r, {12, 12, VW + 16, VH + 16});                // VGA bezel
    SDL_UpdateTexture(tex, nullptr, fb, VW * 4);
    SDL_Rect dst{20, 20, VW, VH}; SDL_RenderCopy(r, tex, nullptr, &dst);

    const int led_off[3] = {70, 12, 12}, led_on_c[3] = {255, 50, 50};
    for (int i = 0; i < 8; i++) {
        int cx = PX + 12 + (7 - i) * 31;
        col(r, 10, 50, 30); disc(r, cx, 60, 13);
        mix(r, led_off, led_on_c, std::sqrt(led_v[i])); disc(r, cx, 60, 10);
        label(r, i, cx, 80);
    }
    for (int i = 0; i < 4; i++) {
        R b = btn_r(i); bool down = ((btn_key | btn_mouse) >> i) & 1;
        col(r, 25, 25, 25); fill(r, {b.x - 3, b.y - 3, b.w + 6, b.h + 6});
        col(r, down ? 110 : 200, down ? 110 : 200, down ? 120 : 210); fill(r, b);
        label(r, i, b.x + b.w / 2, b.y + b.h + 8);
    }
    for (int i = 0; i < 8; i++) {
        R s = sw_r(i); bool on = (sw_state >> i) & 1;
        col(r, 25, 25, 25); fill(r, s);
        col(r, 235, 235, 235); fill(r, {s.x + 3, on ? s.y + 3 : s.y + s.h / 2, s.w - 6, s.h / 2 - 3});
        label(r, i, s.x + s.w / 2, s.y + s.h + 8);
    }
    const int seg_off[3] = {28, 40, 34}, seg_on_c[3] = {255, 70, 40};
    for (int d = 0; d < 4; d++) {
        R q = dig_r(d); col(r, 12, 14, 12); fill(r, {q.x - 6, q.y - 6, q.w + 12, q.h + 12});
        seg7(r, q, seg_v[d], seg_off, seg_on_c);
    }
    SDL_RenderPresent(r);
}

int main(int argc, char** argv) {
    uint64_t max_cycles = 0; const char *shot = nullptr, *vcd = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--sw") && i + 1 < argc)  sw_state = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--btn") && i + 1 < argc) btn_key = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--shot") && i + 1 < argc) shot = argv[++i];
        else if (!strcmp(argv[i], "--vcd") && i + 1 < argc)  vcd = argv[++i];
        else { fprintf(stderr, "usage: vboard [--cycles N] [--sw V] [--btn V] [--shot f.bmp] [--vcd f.vcd]\n"); return 1; }
    }
    bool headless = max_cycles > 0;
    if (headless) setenv("SDL_VIDEODRIVER", "dummy", 1);

    Verilated::traceEverOn(vcd != nullptr);
    dut = new Vpcb; dut->uart_rx = 1;
    for (auto& p : fb) p = 0xFF050505;
#ifdef WITH_VCD
    if (vcd) { tfp = new VerilatedVcdC; dut->trace(tfp, 1); tfp->open(vcd); }
#else
    if (vcd) { fprintf(stderr, "this binary was built without tracing (use make wave)\n"); return 1; }
#endif

    SDL_Init(SDL_INIT_VIDEO);
    SDL_Window* win = SDL_CreateWindow("vboard", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIN_W, WIN_H,
                                       headless ? SDL_WINDOW_HIDDEN : 0);
    SDL_Renderer* ren = SDL_CreateRenderer(win, -1, headless ? SDL_RENDERER_SOFTWARE : SDL_RENDERER_ACCELERATED);
    if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    SDL_Texture* tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, VW, VH);

    if (headless) {
        dut->btn = btn_key; dut->sw = sw_state;
        uint64_t tail = max_cycles < 420000 ? max_cycles : 420000;     // last ~1 VGA frame sets LED/7-seg state
        for (uint64_t i = 0; i < max_cycles - tail; i++) tick();
        reset_acc();
        for (uint64_t i = 0; i < tail; i++) tick();
        finish_frame(true);
        render(ren, tex);
        if (shot) {
            SDL_Surface* s = SDL_CreateRGBSurface(0, WIN_W, WIN_H, 32, 0xFF0000, 0xFF00, 0xFF, 0xFF000000);
            SDL_RenderReadPixels(ren, nullptr, s->format->format, s->pixels, s->pitch);
            SDL_SaveBMP(s, shot);
        }
    } else {
        fprintf(stderr, "vboard: keys 0-7 = switches, A S D F = buttons, Esc = quit\n");
        const uint64_t per_frame = (uint64_t)(CLK_HZ / 60);
        bool quit = false; int held = -1;
        auto t_stat = Clock::now(); uint64_t c_stat = 0;
        while (!quit) {
            auto t0 = Clock::now();
            SDL_Event e;
            while (SDL_PollEvent(&e)) {
                if (e.type == SDL_QUIT) quit = true;
                else if (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP) {
                    bool dn = e.type == SDL_KEYDOWN; int k = e.key.keysym.sym;
                    if (k == SDLK_ESCAPE) quit = true;
                    if (k >= '0' && k <= '7' && dn && !e.key.repeat) sw_state ^= 1 << (k - '0');
                    const char* bk = "asdf";
                    for (int i = 0; i < 4; i++) if (k == bk[i]) btn_key = dn ? (btn_key | 1 << i) : (btn_key & ~(1 << i));
                } else if (e.type == SDL_MOUSEBUTTONDOWN) {
                    for (int i = 0; i < 4; i++) if (hit(btn_r(i), e.button.x, e.button.y)) { held = i; btn_mouse = 1 << i; }
                    for (int i = 0; i < 8; i++) if (hit(sw_r(i), e.button.x, e.button.y)) sw_state ^= 1 << i;
                } else if (e.type == SDL_MOUSEBUTTONUP) { held = -1; btn_mouse = 0; }
            }
            dut->btn = btn_key | btn_mouse; dut->sw = sw_state;
            uint64_t start = cyc;
            while (cyc - start < per_frame) {
                for (int i = 0; i < 4096 && cyc - start < per_frame; i++) tick();
                if (Clock::now() - t0 > std::chrono::milliseconds(12)) break;   // can't keep real time: slow down
            }
            finish_frame(); render(ren, tex);
            std::this_thread::sleep_until(t0 + std::chrono::microseconds(16667));
            double dt = std::chrono::duration<double>(Clock::now() - t_stat).count();
            if (dt > 1.0) {
                char t[96]; snprintf(t, sizeof t, "vboard - %.0f%% of real time (%.1f Mcycles/s)",
                                     100.0 * (cyc - c_stat) / (CLK_HZ * dt), (cyc - c_stat) / dt / 1e6);
                SDL_SetWindowTitle(win, t); t_stat = Clock::now(); c_stat = cyc;
            }
        }
    }
#ifdef WITH_VCD
    if (tfp) tfp->close();
#endif
    dut->final();
    return 0;
}
