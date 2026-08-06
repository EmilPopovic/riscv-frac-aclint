// Copyright 2026 Emil Popović
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0
//
// Emil Popović <mail@emilpopovic.me>

module aclint_core #(
    parameter  int unsigned NumHarts = 1,
    localparam int unsigned HartIdW  = (NumHarts > 1) ? $clog2(NumHarts) : 1
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // Increment mtime on tick. Must be a single-cycle pulse in the clk_i domain.
    input  logic        tick_i,

    // Data written to a register
    input  logic [31:0] wdata_i,
    // Data read from a register
    output logic [31:0] rdata_o,
    // Write strobe per byte. Any bit set makes the access a write, and only the
    // strobed bytes are updated. All zero is a read.
    input  logic [3:0]  wstrb_i,

    // Selects which hart's msip/mtimecmp/setssip is targeted. Ignored for mtime.
    input  logic [HartIdW-1:0] hart_idx_i,

    // Register enables, one at a time
    input  logic        mtime_en_i,
    input  logic        mtimeh_en_i,
    input  logic        mtimecmp_en_i,
    input  logic        mtimecmph_en_i,
    input  logic        msip_en_i,
    input  logic        setssip_en_i,

    // Interrupt outputs, one bit per hart
    output logic [NumHarts-1:0] mtip_o,
    output logic [NumHarts-1:0] msip_o,

    // Supervisor software interrupt set request, one bit per hart.
    // Asserted for a single cycle.
    output logic [NumHarts-1:0] ssip_set_o,

    // Time output, broadcast for rdtime/rdtimeh
    output logic [63:0] mtime_o
);

    logic [63:0] mtime;
    logic [63:0] mtimecmp [NumHarts];
    logic [NumHarts-1:0] msip;

    // Only matters when NumHarts is not a power of two
    logic               hart_idx_ok;
    logic [HartIdW-1:0] hart_idx;

    assign hart_idx_ok = (32'(hart_idx_i) < NumHarts);
    assign hart_idx    = hart_idx_ok ? hart_idx_i : '0;

    assign mtime_o = mtime;
    assign msip_o  = msip;

    // Merge wdata_i into a register word, byte by byte, per wstrb_i.
    // Bytes with a deasserted strobe keep their old value.
    function automatic logic [31:0] apply_wstrb(
        input logic [31:0] old_data,
        input logic [31:0] new_data,
        input logic [3:0]  strb
    );
        logic [31:0] merged;
        for (int b = 0; b < 4; b++) begin
            merged[8*b +: 8] = strb[b] ? new_data[8*b +: 8] : old_data[8*b +: 8];
        end
        return merged;
    endfunction

    // Any strobe bit makes this a write, none makes it a read. Gating the
    // register writes on this also keeps a read from shadowing a tick.
    logic wr;
    assign wr = |wstrb_i;

    // Global mtime
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            mtime <= 64'd0;
        end else begin
            // Write to mtime takes priority over incrementing it. A partial write still drops the tick.
            if (wr && mtime_en_i)       mtime[31:0]  <= apply_wstrb(mtime[31:0],  wdata_i, wstrb_i);
            else if (wr && mtimeh_en_i) mtime[63:32] <= apply_wstrb(mtime[63:32], wdata_i, wstrb_i);
            else if (tick_i)            mtime        <= mtime + 64'd1;
        end
    end

    // Per-hart state and comparators
    for (genvar h = 0; h < NumHarts; h++) begin : gen_hart

        logic hart_sel;
        assign hart_sel = hart_idx_ok && (hart_idx_i == h);

        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                mtimecmp[h] <= 64'hFFFF_FFFF_FFFF_FFFF;
                msip[h]     <= 1'b0;
            end else begin
                if (wr && hart_sel && mtimecmp_en_i)
                    mtimecmp[h][31:0]  <= apply_wstrb(mtimecmp[h][31:0],  wdata_i, wstrb_i);
                if (wr && hart_sel && mtimecmph_en_i)
                    mtimecmp[h][63:32] <= apply_wstrb(mtimecmp[h][63:32], wdata_i, wstrb_i);
                // msip is bit 0 of its word, so only byte 0's strobe reaches it
                if (hart_sel && msip_en_i && wstrb_i[0])
                    msip[h]            <= wdata_i[0];
            end
        end

        // Level-sensitive unsigned 64-bit compare.
        // Registered to keep the comparator off the mtime fanout path.
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) mtip_o[h] <= 1'b0;
            else         mtip_o[h] <= (mtime >= mtimecmp[h]);
        end

        // Writing 1 raises the hart's supervisor software interrupt, writing 0 does nothing.
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) ssip_set_o[h] <= 1'b0;
            else         ssip_set_o[h] <= hart_sel && setssip_en_i && wstrb_i[0] && wdata_i[0];
        end

    end : gen_hart

    // Read mux
    logic [63:0] mtimecmp_sel;
    logic        msip_sel;

    assign mtimecmp_sel = hart_idx_ok ? mtimecmp[hart_idx] : 64'd0;
    assign msip_sel     = hart_idx_ok ? msip[hart_idx]     : 1'b0;

    assign rdata_o = mtime_en_i     ? mtime[31:0]         :
                     mtimeh_en_i    ? mtime[63:32]        :
                     mtimecmp_en_i  ? mtimecmp_sel[31:0]  :
                     mtimecmph_en_i ? mtimecmp_sel[63:32] :
                     msip_en_i      ? {31'd0, msip_sel}   :
                     32'd0;

`ifndef SYNTHESIS
    // Enables are documented as one-hot-or-zero
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        $onehot0({mtime_en_i, mtimeh_en_i, mtimecmp_en_i, mtimecmph_en_i,
                  msip_en_i, setssip_en_i}))
      else $error("aclint_core: more than one register enable asserted");

    // Decoder should never present an out-of-range hart index
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (mtimecmp_en_i || mtimecmph_en_i || msip_en_i || setssip_en_i) |-> hart_idx_ok)
      else $error("aclint_core: hart_idx_i out of range");
`endif

endmodule
