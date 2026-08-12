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

module aclint_flat #(
    parameter int unsigned NumHarts = 1,
    // Fractional tick generator parameters
    parameter int unsigned TickW         = 26,
    parameter int unsigned DefaultTarget = 1,
    parameter int unsigned DefaultSource = 1,
    // Register interface parameters
    parameter int AW = 32,
    parameter int DW = 32
) (
    input logic                 clk_i,
    input logic                 rst_ni,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [AW-1:0]       addr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                write_i,
    output logic [DW-1:0]       rdata_o,
    input  logic [DW-1:0]       wdata_i,
    input  logic [DW/8-1:0]     wstrb_i,
    output logic                error_o,
    input  logic                valid_i,
    output logic                ready_o,

    // Interrupt outputs, one bit per hart
    output logic [NumHarts-1:0] mtip_o,
    output logic [NumHarts-1:0] msip_o,

    // Supervisor software interrupt set request, one bit per hart, single cycle.
    // See aclint_core for why this is a set pulse rather than a pending bit.
    output logic [NumHarts-1:0] ssip_set_o,

    // Time output, broadcast for rdtime/rdtimeh
    output logic [63:0]         mtime_o
);

    localparam int unsigned MaxHarts = 4095;

    // Parameter checks
    if (DW != 32) begin : gen_dw_check
        $fatal(1, "aclint_flat: DW must be 32, got %0d", DW);
    end
    if (AW < 17 || AW > 32) begin : gen_aw_check
        $fatal(1, "aclint_flat: AW must be in [17, 32], got %0d", AW);
    end
    if (NumHarts < 1 || NumHarts > MaxHarts) begin : gen_numharts_check
        $fatal(1, "aclint_flat: NumHarts must be in [1, %0d], got %0d", MaxHarts, NumHarts);
    end
    if (TickW < 1 || TickW > 32) begin : gen_tickw_check
        $fatal(1, "aclint_flat: TickW must be in [1, 32], got %0d", TickW);
    end
    if (TickW < 32 && DefaultTarget >= (32'd1 << TickW)) begin : gen_default_target_check
        $fatal(1, "aclint_flat: DefaultTarget does not fit in TickW bits");
    end
    if (TickW < 32 && DefaultSource >= (32'd1 << TickW)) begin : gen_default_source_check
        $fatal(1, "aclint_flat: DefaultSource does not fit in TickW bits");
    end

    localparam int unsigned HartIdW = (NumHarts > 1) ? $clog2(NumHarts) : 1;

    // Register map, offsets relative to the base the interconnect assigns to this device.
    //   0x00000 + 4*h   MSIP[h]      MSWI device,   region ends at 0x03FFF
    //   0x04000 + 8*h   MTIMECMP[h]  MTIMER device, region ends at 0x0BFF7
    //   0x0BFF8         MTIME        MTIMER device
    //   0x0C000         TICKTARGET   tick generator target rate
    //   0x0C004         TICKSOURCE   tick generator source rate
    //   0x10000 + 4*h   SETSSIP[h]   SSWI device,   region ends at 0x13FFF
    localparam logic [16:0] MsipBase      = 17'h0_0000;
    localparam logic [16:0] MtimecmpBase  = 17'h0_4000;
    localparam logic [16:0] MtimeBase     = 17'h0_BFF8;
    localparam logic [16:0] TickTargetOff = 17'h0_C000;
    localparam logic [16:0] TickSourceOff = 17'h0_C004;
    localparam logic [16:0] SetssipBase   = 17'h1_0000;
    localparam logic [16:0] SetssipEnd    = 17'h1_4000;


    // Word-aligned offset into the region.
    // The low two address bits are ignored because byte lanes come from wstrb.
    logic [16:0] off;
    logic        in_region;

    assign off = {addr_i[16:2], 2'b00};

    // Anything above the 128 KiB the map lives in is not ours to answer
    if (AW > 17) begin : gen_region_check
        assign in_region = (addr_i[AW-1:17] == '0);
    end else begin : gen_no_region_check
        assign in_region = 1'b1;
    end

    // MSWI
    logic        in_msip;
    logic [11:0] msip_idx;

    assign msip_idx = 12'((off - MsipBase) >> 2);
    assign in_msip  = (off < MtimecmpBase) && (32'(msip_idx) < NumHarts);

    // MTIMER
    logic        in_mtimecmp;
    logic [11:0] mtimecmp_idx;
    logic        mtimecmp_hi;

    assign mtimecmp_idx = 12'((off - MtimecmpBase) >> 3);
    assign mtimecmp_hi  = off[2];
    assign in_mtimecmp  = (off >= MtimecmpBase) && (off < MtimeBase) &&
                          (32'(mtimecmp_idx) < NumHarts);

    logic in_mtime;
    logic mtime_hi;

    assign in_mtime = (off >= MtimeBase) && (off < TickTargetOff);
    assign mtime_hi = off[2];

    // Tick generator configuration
    logic in_target, in_source;

    assign in_target = (off == TickTargetOff);
    assign in_source = (off == TickSourceOff);

    // SSWI
    logic        in_setssip;
    logic [11:0] setssip_idx;

    assign setssip_idx = 12'((off - SetssipBase) >> 2);
    assign in_setssip  = (off >= SetssipBase) && (off < SetssipEnd) &&
                         (32'(setssip_idx) < NumHarts);

    // A request that decoded to a register
    logic hit, acc;

    assign hit = in_msip | in_mtimecmp | in_mtime | in_target | in_source | in_setssip;
    assign acc = valid_i && in_region && hit;

    assign ready_o = 1'b1;
    assign error_o = valid_i && !(in_region && hit);

    // Only a write reaches the register state. The core takes a zero strobe as a
    // read, so gating here is what separates the two directions.
    logic [3:0] acc_wstrb;
    assign acc_wstrb = (acc && write_i) ? wstrb_i : 4'b0000;

    // Byte strobes expanded to a bit mask, for the registers held locally
    logic [TickW-1:0] wmask;
    always_comb begin
        for (int unsigned i = 0; i < TickW; i++) wmask[i] = acc_wstrb[i/8];
    end

    // Tick generator rates. Writing either one reloads the accumulator so the
    // new ratio takes effect from a known state instead of from whatever partial
    // fraction was left over.
    logic [TickW-1:0] target_q, source_q;
    logic             load_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            target_q <= TickW'(DefaultTarget);
            source_q <= TickW'(DefaultSource);
            load_q   <= 1'b0;
        end else begin
            // Pulsed the cycle after the write, by which point target_q/source_q
            // already carry the new rate frac_tick has to reload from.
            load_q <= 1'b0;
            if (in_target && |acc_wstrb) begin
                target_q <= (target_q & ~wmask[TickW-1:0]) | (wdata_i[TickW-1:0] & wmask[TickW-1:0]);
                load_q   <= 1'b1;
            end
            if (in_source && |acc_wstrb) begin
                source_q <= (source_q & ~wmask[TickW-1:0]) | (wdata_i[TickW-1:0] & wmask[TickW-1:0]);
                load_q   <= 1'b1;
            end
        end
    end

    logic tick;

    frac_tick #(
        .W ( TickW )
    ) i_frac_tick (
        .clk_i,
        .rst_ni,
        .target_i ( target_q ),
        .source_i ( source_q ),
        .load_i   ( load_q   ),
        .tick_o   ( tick     )
    );

    // Register enables, one-hot-or-zero
    logic mtime_en, mtimeh_en, mtimecmp_en, mtimecmph_en, msip_en, setssip_en;

    assign mtime_en     = acc && in_mtime    && !mtime_hi;
    assign mtimeh_en    = acc && in_mtime    &&  mtime_hi;
    assign mtimecmp_en  = acc && in_mtimecmp && !mtimecmp_hi;
    assign mtimecmph_en = acc && in_mtimecmp &&  mtimecmp_hi;
    assign msip_en      = acc && in_msip;
    assign setssip_en   = acc && in_setssip;

    // The three per-hart registers live in disjoint regions, so only one index is
    // ever live and they can share a single port into the core.
    logic [HartIdW-1:0] hart_idx;
    assign hart_idx = in_mtimecmp ? HartIdW'(mtimecmp_idx) :
                      in_setssip  ? HartIdW'(setssip_idx)  :
                                    HartIdW'(msip_idx);

    logic [31:0] core_rdata;

    aclint_core #(
        .NumHarts ( NumHarts )
    ) i_aclint_core (
        .clk_i,
        .rst_ni,
        .tick_i         ( tick         ),
        .wdata_i        ( wdata_i      ),
        .rdata_o        ( core_rdata   ),
        .wstrb_i        ( acc_wstrb    ),
        .hart_idx_i     ( hart_idx     ),
        .mtime_en_i     ( mtime_en     ),
        .mtimeh_en_i    ( mtimeh_en    ),
        .mtimecmp_en_i  ( mtimecmp_en  ),
        .mtimecmph_en_i ( mtimecmph_en ),
        .msip_en_i      ( msip_en      ),
        .setssip_en_i   ( setssip_en   ),
        .mtip_o,
        .msip_o,
        .ssip_set_o,
        .mtime_o
    );

    assign rdata_o = in_target ? {{(32-TickW){1'b0}}, target_q} :
                     in_source ? {{(32-TickW){1'b0}}, source_q} :
                     core_rdata;

endmodule
