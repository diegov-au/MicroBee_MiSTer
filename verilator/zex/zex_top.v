//============================================================================
// ZEXDOC / ZEXALL testbench top.
//
// Bare tv80 against a flat, asynchronous 64K RAM - deliberately nothing else.
// The point of this gate is to validate the CPU's instruction semantics before
// the MicroBee core starts depending on them, so the memory here is as dumb as
// possible: no clock enable, no banking, no wait states. A failure means tv80,
// not microbee_mem.
//
// The CP/M BDOS stub lives in Z80 code (see zex_main.cpp), so console output
// arrives here as OUT ($01),A and termination as OUT ($00),A. That means the
// harness never has to reach inside the CPU for register state.
//============================================================================

`timescale 1ps / 1ps

module zex_top
(
	input             clk,
	input             reset,

	output     [15:0] dbg_pc,
	output            dbg_fetch,

	output            out_stb,     // one-shot on an I/O write
	output      [7:0] out_port,
	output      [7:0] out_data
);

wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;

// Flat 64K, combinational read. zex_main.cpp pokes this directly before the
// run (program image, BDOS stub, CP/M page-zero vectors).
// Only this needs to be reachable from C++; marking it individually lets us
// drop --public-flat-rw, which otherwise makes every signal public and blocks
// most of Verilator's optimisation (worth ~5x on this design).
reg [7:0] mem [0:65535] /* verilator public_flat_rw */;

wire [7:0] mem_q = mem[cpu_addr];

wire mem_wr = ~mreq_n & ~wr_n & rfsh_n;
wire io_rd  = ~iorq_n & ~rd_n & m1_n;
wire io_wr  = ~iorq_n & ~wr_n & m1_n;

always @(posedge clk) begin
	if (mem_wr) mem[cpu_addr] <= cpu_dout;
end

// Unmapped input ports read as 0xFF.
wire [7:0] cpu_din = io_rd ? 8'hFF : mem_q;

tv80s_ce cpu
(
	.reset_n (~reset),
	.clk     (clk),
	.cen     (1'b1),
	.wait_n  (1'b1),
	.int_n   (1'b1),
	.nmi_n   (1'b1),
	.busrq_n (1'b1),
	.m1_n    (m1_n),
	.mreq_n  (mreq_n),
	.iorq_n  (iorq_n),
	.rd_n    (rd_n),
	.wr_n    (wr_n),
	.rfsh_n  (rfsh_n),
	.halt_n  (),
	.busak_n (),
	.A       (cpu_addr),
	.di      (cpu_din),
	.dout    (cpu_dout)
);

// One-shot so the harness sees exactly one event per OUT.
reg io_wr_d;
always @(posedge clk) io_wr_d <= io_wr;

assign out_stb  = io_wr & ~io_wr_d;
assign out_port = cpu_addr[7:0];
assign out_data = cpu_dout;

// Opcode fetch, used only to spot the jump to $0000 that ends the run.
reg [15:0] pc_r;
reg        fetch_r;
always @(posedge clk) begin
	fetch_r <= 1'b0;
	if (~m1_n & ~mreq_n & ~rd_n & rfsh_n) begin
		pc_r    <= cpu_addr;
		fetch_r <= 1'b1;
	end
end

assign dbg_pc    = pc_r;
assign dbg_fetch = fetch_r;

endmodule
