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

    // Register interface
    input  logic [AW-1:0]       addr_i,
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

    // Time output, broadcast for rdtime/rdtimeh
    output logic [63:0]         mtime_o
);

    logic [TickW-1:0] target, source;
    logic tick;

    frac_tick #(
        .W ( TickW )
    ) i_frac_tick (
        .clk_i,
        .rst_ni,
        .target_i ( target ),
        .source_i ( source ),
        .load_i   (  ),
        .tick_o   ( tick   )
    );

    aclint_core #(
        .NumHarts ( NumHarts )
    ) i_aclint_core (
        .clk_i,
        .rst_ni,
        .tick_i         ( tick ),
        .wdata_i        (  ),
        .rdata_o        (  ),
        .wstrb_i        (  ),
        .hart_idx_i     (  ),
        .mtime_en_i     (  ),
        .mtimeh_en_i    (  ),
        .mtimecmp_en_i  (  ),
        .mtimecmph_en_i (  ),
        .msip_en_i      (  ),
        .mtip_o,
        .msip_o,
        .mtime_o
    );

endmodule
