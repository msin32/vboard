// The mock PCB. "chip" is the FPGA, regenerated from the bitstream (see vboard.mk),
// or, with -DRTL, your RTL directly (make run-rtl).
// The connections below are generated from vboard.pcf, so the wiring always matches
// the constraints your design was placed with. Pins your design leaves unused simply
// float, exactly like on real hardware.
module pcb (
    input        clk,        // 25 MHz oscillator
    input  [3:0] btn,        // push buttons, active-high
    input  [7:0] sw,         // slide switches
    output [7:0] led,
    output [6:0] seg,        // {g,f,e,d,c,b,a}, active-high
    output [3:0] dig,        // digit enables, dig[0] = rightmost
    output [3:0] vga_r, vga_g, vga_b,
    output       vga_hs, vga_vs,
    output       uart_tx,    // 115200 8N1, printed to the terminal
    input        uart_rx     // (idle high)
);
`ifdef RTL
    // fast mode: your design wired straight in by port name (no place & route)
    `TOP_MODULE fpga (.*);
`else
    chip fpga (.clk(clk)
`include "pcb_conn.vh"
    );
`endif
endmodule
