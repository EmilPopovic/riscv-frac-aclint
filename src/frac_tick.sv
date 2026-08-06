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

module frac_tick #(
    parameter int W = 26
) (
    input logic         clk_i,
    input logic         rst_ni,
    // Target rate  (e.g. 10, 10_000_000)
    input logic [W-1:0] target_i,
    // Source clock (e.g. 33, 33_000_000)
    input logic [W-1:0] source_i,
    // Pulse on config write
    input logic         load_i,
    // Avg rate = f_clk * target/source
    output logic        tick_o
);

    logic signed [W:0] acc, step_hi, step_lo;

    assign step_lo = $signed({1'b0, target_i});
    assign step_hi = $signed({1'b0, target_i}) - $signed({1'b0, source_i});

    assign tick_o = !acc[W];  // acc >= 0

    logic src_zero;
    assign src_zero = (source_i == '0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if      (!rst_ni)  acc <= '1;
        else if (load_i)   acc <= ~$signed({1'b0, source_i});
        else if (src_zero) acc <= '1;
        else               acc <= acc + (tick_o ? step_hi : step_lo);
    end

endmodule
