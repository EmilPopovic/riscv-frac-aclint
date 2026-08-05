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

module clint #(
    parameter int unsigned NumHarts = 1,
    // Fractional tick generator parameters
    parameter int unsigned TickW         = 26,
    parameter int unsigned DefaultTarget = 1,
    parameter int unsigned DefaultSource = 1,
    // Register interface parameters
    parameter type reg_req_t = logic,
    parameter type reg_rsp_t = logic,
    parameter int AW = 32,
    parameter int DW = 32
) (
    input  logic                clk_i,
    input  logic                rst_ni,
    input  reg_req_t            reg_req_i,
    output reg_rsp_t            reg_rsp_o,
    output logic [NumHarts-1:0] mtip_o,
    output logic [NumHarts-1:0] msip_o,
    output logic [63:0]         mtime_o
);

    clint_flat #(
        .NumHarts ( NumHarts ),
        .AW       ( AW       ),
        .DW       ( DW       )
    ) i_clint_flat (
        .clk_i,
        .rst_ni,
        .addr_i  ( reg_req_i.addr  ),
        .write_i ( reg_req_i.write ),
        .rdata_o ( reg_rsp_o.rdata ),
        .wdata_i ( reg_req_i.wdata ),
        .wstrb_i ( reg_req_i.wstrb ),
        .error_o ( reg_rsp_o.error ),
        .valid_i ( reg_req_i.valid ),
        .ready_o ( reg_rsp_o.ready ),
        .mtip_o,
        .msip_o,
        .mtime_o
    );

endmodule
