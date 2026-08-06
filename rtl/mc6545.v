//============================================================================
// mc6545 - SY6545-1 / MC6845-compatible CRT controller.
//
// Written for the MicroBee, which uses the 6545 in two ways that a plain 6845
// core does not cover:
//
//  1. The keyboard is scanned through the LIGHT PEN. There is no light pen on
//     a MicroBee - the key matrix is wired so that a pressed key strobes LPEN
//     with an address encoding which key it is. Two things drive that scan:
//     the natural walk of MA during display refresh, and an explicit strobe
//     from the transparent-addressing registers (R18/R19 + R31).
//
//  2. Status (read at port $0C) carries update-ready in bit 7, light-pen-full
//     in bit 6 and vertical blanking in bit 5.
//
// References: MAME src/mame/ausnz/mbee_v.cpp (m6545_data_w, oldkb_matrix_r),
// ubee512 src/crtc.c (crtc_status_r, crtc_lpen, CRTC_DOSETADDR).
//
// Timing is generated properly from R0-R9 rather than synthesised from a fixed
// VGA raster, so the core produces the machine's native ~15.625kHz / 50Hz and
// MiSTer's scaler can do its job.
//============================================================================

module mc6545
(
	input             clk,          // clk_sys
	input             reset,
	input             ce,           // character clock enable (1.6875 MHz)

	// CPU interface. rs=0 -> address register (write) / status (read)
	//                rs=1 -> data register
	input             cs,
	input             rs,
	input             we,
	input             re,
	input       [7:0] din,
	output reg  [7:0] dout,

	// Video
	output     [13:0] MA,
	output      [4:0] RA,
	output reg        DE,
	output reg        HSYNC,
	output reg        VSYNC,
	output            CURSOR,
	output            HBLANK,
	output            VBLANK,
	output            alt_charset,   // R12[5:4]==2'b10 selects the second char set

	// Active-area geometry, for the caller's aspect-ratio calculation. The
	// MicroBee reprograms the CRTC between 64x16 and 80x24, so these change at
	// runtime and a fixed VIDEO_ARX/ARY cannot be right for both.
	output      [7:0] disp_cols,     // R1  characters across
	output      [6:0] disp_rows,     // R6  character rows down
	output      [4:0] disp_row_h,    // R9  scanlines per row, minus one

	// Keyboard scan (MicroBee light-pen wiring)
	output     [13:0] update_addr,   // R18/R19
	output reg        update_strobe /* verilator public_flat_rw */, // 1-clk pulse on an R31 access
	input             lpen_set,      // key found pressed at the scanned address
	input      [13:0] lpen_din
);

//--------------------------------------------------------------------------
// Register file
//--------------------------------------------------------------------------
reg  [4:0] addr_reg;

// The register file is marked public so the Verilator harness can dump it in
// its stop report. See the note in microbee_core.v on why this is per-signal
// rather than a global --public-flat-rw.
reg  [7:0] r0_h_total    /* verilator public_flat_rw */;
reg  [7:0] r1_h_disp     /* verilator public_flat_rw */;
reg  [7:0] r2_h_sync_pos /* verilator public_flat_rw */;
reg  [7:0] r3_sync_width /* verilator public_flat_rw */;
reg  [6:0] r4_v_total    /* verilator public_flat_rw */;
reg  [4:0] r5_v_adjust   /* verilator public_flat_rw */;
reg  [6:0] r6_v_disp     /* verilator public_flat_rw */;
reg  [6:0] r7_v_sync_pos /* verilator public_flat_rw */;
reg  [1:0] r8_interlace;
reg  [4:0] r9_max_ra     /* verilator public_flat_rw */;
reg  [6:0] r10_cur_start;
reg  [4:0] r11_cur_end;
reg [13:0] r12_13_start  /* verilator public_flat_rw */;
reg [13:0] r14_15_cursor /* verilator public_flat_rw */;
reg [13:0] r16_17_lpen;
reg [13:0] r18_19_update;

reg        lpen_valid;
reg        update_ready;

assign update_addr = r18_19_update;

// MAME m6545_data_w case 12: writing R12 with bits 5:4 == 10 re-copies the
// character generator from chargen+$800, i.e. selects the alternate set.
assign alt_charset = (r12_13_start[13:12] == 2'b10);

assign disp_cols  = r1_h_disp;
assign disp_rows  = r6_v_disp;
assign disp_row_h = r9_max_ra;

wire [3:0] hsync_width = r3_sync_width[3:0];
// Programmable vsync width on the 6545; 0 means 16 scanlines.
wire [4:0] vsync_width = (r3_sync_width[7:4] == 4'd0) ? 5'd16 : {1'b0, r3_sync_width[7:4]};

//--------------------------------------------------------------------------
// CPU register access
//--------------------------------------------------------------------------
always @(posedge clk) begin
	update_strobe <= 1'b0;

	if (reset) begin
		addr_reg      <= 5'd0;
		r0_h_total    <= 8'd0;
		r1_h_disp     <= 8'd0;
		r2_h_sync_pos <= 8'd0;
		r3_sync_width <= 8'd0;
		r4_v_total    <= 7'd0;
		r5_v_adjust   <= 5'd0;
		r6_v_disp     <= 7'd0;
		r7_v_sync_pos <= 7'd0;
		r8_interlace  <= 2'd0;
		r9_max_ra     <= 5'd0;
		r10_cur_start <= 7'd0;
		r11_cur_end   <= 5'd0;
		r12_13_start  <= 14'd0;
		r14_15_cursor <= 14'd0;
		r16_17_lpen   <= 14'd0;
		r18_19_update <= 14'd0;
		lpen_valid    <= 1'b0;
		update_ready  <= 1'b0;
	end
	else begin
		// A pressed key strobes the light pen. Only the first one latches -
		// the register stays full until the CPU reads R16/R17.
		if (lpen_set && !lpen_valid) begin
			r16_17_lpen <= lpen_din;
			lpen_valid  <= 1'b1;
		end

		if (cs && we) begin
			if (!rs) addr_reg <= din[4:0];
			else case (addr_reg)
				5'd0:  r0_h_total    <= din;
				5'd1:  r1_h_disp     <= din;
				5'd2:  r2_h_sync_pos <= din;
				5'd3:  r3_sync_width <= din;
				5'd4:  r4_v_total    <= din[6:0];
				5'd5:  r5_v_adjust   <= din[4:0];
				5'd6:  r6_v_disp     <= din[6:0];
				5'd7:  r7_v_sync_pos <= din[6:0];
				5'd8:  r8_interlace  <= din[1:0];
				5'd9:  r9_max_ra     <= din[4:0];
				5'd10: r10_cur_start <= din[6:0];
				5'd11: r11_cur_end   <= din[4:0];
				5'd12: r12_13_start[13:8] <= din[5:0];
				5'd13: r12_13_start[7:0]  <= din;
				5'd14: r14_15_cursor[13:8] <= din[5:0];
				5'd15: r14_15_cursor[7:0]  <= din;
				// R16/R17 are read-only (light pen).
				5'd18: r18_19_update[13:8] <= din[5:0];
				5'd19: r18_19_update[7:0]  <= din;
				5'd31: begin
					// Transparent-address strobe: this is what makes the
					// keyboard scan happen on demand.
					update_strobe <= 1'b1;
					update_ready  <= 1'b0;
				end
				default: ;
			endcase
		end

		if (cs && re) begin
			if (!rs) begin
				// Reading status arms update-ready (ubee512 crtc_status_r).
				update_ready <= 1'b1;
			end
			else case (addr_reg)
				5'd16, 5'd17: lpen_valid <= 1'b0;   // reading LPEN clears the flag
				5'd31: begin
					update_strobe <= 1'b1;
					update_ready  <= 1'b0;
				end
				default: ;
			endcase
		end
	end
end

// Read mux
always @(*) begin
	if (!rs) begin
		dout = {update_ready, lpen_valid, VBLANK, 5'd0};
	end
	else case (addr_reg)
		5'd12:   dout = {2'b00, r12_13_start[13:8]};
		5'd13:   dout = r12_13_start[7:0];
		5'd14:   dout = {2'b00, r14_15_cursor[13:8]};
		5'd15:   dout = r14_15_cursor[7:0];
		5'd16:   dout = {2'b00, r16_17_lpen[13:8]};
		5'd17:   dout = r16_17_lpen[7:0];
		5'd18:   dout = {2'b00, r18_19_update[13:8]};
		5'd19:   dout = r18_19_update[7:0];
		default: dout = 8'h00;
	endcase
end

//--------------------------------------------------------------------------
// Timing generator
//--------------------------------------------------------------------------
reg  [7:0] h_cnt;        // character position within the line
reg  [4:0] ra_cnt;       // scanline within the character row
reg  [6:0] row_cnt;      // character row
reg  [3:0] hsync_cnt;
reg  [4:0] vsync_cnt;
reg        in_adjust;    // running the R5 vertical-total-adjust scanlines
reg  [4:0] adjust_cnt;

reg [13:0] ma_row;       // address at the start of the current character row
reg [13:0] ma_cnt;       // address of the character being fetched

assign MA = ma_cnt;
assign RA = ra_cnt;

wire line_end  = (h_cnt == r0_h_total);
wire row_end   = (ra_cnt == r9_max_ra);
wire frame_end = (row_cnt == r4_v_total);

reg v_disp;
reg h_disp;
assign VBLANK = ~v_disp;
assign HBLANK = ~h_disp;

// What v_disp will be during the next character period. v_disp only ever moves
// at line_end, so this mirrors the vertical block below; keep the two in step.
// VBLANK deliberately stays on `v_disp` - it is already in phase with the
// counters, and only DE needs the look-ahead.
reg v_disp_next;
always @(*) begin
	v_disp_next = v_disp;
	if (line_end) begin
		if (in_adjust) begin
			if (adjust_cnt == r5_v_adjust) v_disp_next = (r6_v_disp != 7'd0);
		end
		else if (row_end) begin
			if (frame_end) begin
				if (r5_v_adjust == 5'd0) v_disp_next = (r6_v_disp != 7'd0);
			end
			else if (row_cnt + 7'd1 == r6_v_disp) v_disp_next = 1'b0;
		end
	end
end

always @(posedge clk) begin
	if (reset) begin
		h_cnt      <= 8'd0;
		ra_cnt     <= 5'd0;
		row_cnt    <= 7'd0;
		hsync_cnt  <= 4'd0;
		vsync_cnt  <= 5'd0;
		in_adjust  <= 1'b0;
		adjust_cnt <= 5'd0;
		ma_row     <= 14'd0;
		ma_cnt     <= 14'd0;
		DE         <= 1'b0;
		h_disp     <= 1'b1;
		v_disp     <= 1'b1;
		HSYNC      <= 1'b0;
		VSYNC      <= 1'b0;
	end
	else if (ce) begin

		//------------------------------------------------------------------
		// Horizontal
		//------------------------------------------------------------------
		if (line_end) begin
			h_cnt  <= 8'd0;
			ma_cnt <= ma_row;
		end
		else begin
			h_cnt <= h_cnt + 8'd1;
			if (h_cnt < r1_h_disp) ma_cnt <= ma_cnt + 14'd1;
		end

		// Display enable: inside the horizontal and vertical displayed areas.
		// Tracked one character ahead because the counters update on ce - and
		// that has to apply to BOTH axes. Using `v_disp` here instead of
		// `v_disp_next` computes the frame's first character period against the
		// PREVIOUS frame's v_disp, which is still 0, so the first cell of the
		// first scanline is blanked. One cell, once per frame, and invisible in
		// text because scanline 0 of a char-ROM glyph is blank either way - the
		// same way the ma_cnt row-boundary bug below hid for three milestones.
		h_disp <= (line_end ? 8'd0 : h_cnt + 8'd1) < r1_h_disp;
		DE     <= ((line_end ? 8'd0 : h_cnt + 8'd1) < r1_h_disp) && v_disp_next;

		//------------------------------------------------------------------
		// Horizontal sync
		//------------------------------------------------------------------
		if (HSYNC) begin
			if (hsync_cnt == hsync_width - 4'd1) HSYNC <= 1'b0;
			hsync_cnt <= hsync_cnt + 4'd1;
		end
		else if (h_cnt == r2_h_sync_pos && hsync_width != 4'd0) begin
			HSYNC     <= 1'b1;
			hsync_cnt <= 4'd1;
		end

		//------------------------------------------------------------------
		// Vertical - advances at the end of each scanline
		//------------------------------------------------------------------
		if (line_end) begin

			if (in_adjust) begin
				// Vertical total adjust: R5 extra scanlines before the frame
				// restarts. This is what makes the ~312-line/50Hz raster land
				// exactly rather than approximately.
				if (adjust_cnt == r5_v_adjust) begin
					in_adjust <= 1'b0;
					row_cnt   <= 7'd0;
					ra_cnt    <= 5'd0;
					ma_row    <= r12_13_start;
					ma_cnt    <= r12_13_start;
					v_disp    <= (r6_v_disp != 7'd0);
				end
				else begin
					adjust_cnt <= adjust_cnt + 5'd1;
				end
			end
			else if (row_end) begin
				ra_cnt <= 5'd0;
				ma_row <= ma_row + {6'd0, r1_h_disp};
				// ...and ma_cnt with it. The horizontal block above has already
				// done `ma_cnt <= ma_row` for this line_end, but ma_row is
				// non-blocking, so that loaded the address of the row we are
				// LEAVING. Without this the first scanline of every character
				// row displays the previous row's characters.
				//
				// Text hides it almost perfectly - most char-ROM glyphs have a
				// blank scanline 0, so the wrong data is blank either way - which
				// is why this survived M2 and M3 and only showed up on full-cell
				// PCG graphics, as a missing top border line and stray fragments
				// one row below each graphic.
				ma_cnt <= ma_row + {6'd0, r1_h_disp};

				if (frame_end) begin
					if (r5_v_adjust != 5'd0) begin
						in_adjust  <= 1'b1;
						adjust_cnt <= 5'd0;
					end
					else begin
						row_cnt <= 7'd0;
						ma_row  <= r12_13_start;
						ma_cnt  <= r12_13_start;
						v_disp  <= (r6_v_disp != 7'd0);
					end
				end
				else begin
					row_cnt <= row_cnt + 7'd1;
					if (row_cnt + 7'd1 == r6_v_disp) v_disp <= 1'b0;
				end
			end
			else begin
				ra_cnt <= ra_cnt + 5'd1;
			end

			//--------------------------------------------------------------
			// Vertical sync - starts at the top of row R7, lasts vsync_width
			// scanlines.
			//--------------------------------------------------------------
			if (VSYNC) begin
				if (vsync_cnt == vsync_width - 5'd1) VSYNC <= 1'b0;
				vsync_cnt <= vsync_cnt + 5'd1;
			end
			else if (!in_adjust && row_end && (row_cnt + 7'd1 == r7_v_sync_pos)) begin
				VSYNC     <= 1'b1;
				vsync_cnt <= 5'd1;
			end
		end
	end
end

//--------------------------------------------------------------------------
// Cursor
//--------------------------------------------------------------------------
reg [5:0] blink_cnt;
always @(posedge clk) if (ce && line_end && ra_cnt == 5'd0 && row_cnt == 7'd0) blink_cnt <= blink_cnt + 6'd1;

wire blink_on = (r10_cur_start[6:5] == 2'b00) ? 1'b1 :         // solid
                (r10_cur_start[6:5] == 2'b01) ? 1'b0 :         // no cursor
                (r10_cur_start[6:5] == 2'b10) ? blink_cnt[3] : // blink 1/16
                                                blink_cnt[4];  // blink 1/32

assign CURSOR = DE && blink_on &&
                (ma_cnt == r14_15_cursor) &&
                (ra_cnt >= r10_cur_start[4:0]) &&
                (ra_cnt <= r11_cur_end);

wire _unused = &{1'b0, r8_interlace, 1'b0};

endmodule
