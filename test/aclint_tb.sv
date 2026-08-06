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

`include "register_interface/assign.svh"
`include "register_interface/typedef.svh"

// Self-checking testbench for the ACLINT
module aclint_tb #(
    parameter int unsigned NumHarts = 4
);

    localparam int unsigned TickW         = 26;
    localparam int unsigned DefaultTarget = 1;
    localparam int unsigned DefaultSource = 4;

    // The hart the interrupt tests target. Picked away from hart 0 where the
    // configuration allows, so a decoder that ignores the index gets caught.
    localparam int unsigned TestHart = (NumHarts > 2) ? 2 : 0;
    // Highest implemented hart
    localparam int unsigned TopHart = NumHarts - 1;

    localparam time ClkPeriod = 10ns;

    // Stimuli application and test times, named after the reg_test::reg_driver
    // parameters they stand in for: the request goes up TA into a transfer's
    // cycle and the response is sampled TT into it, still ahead of the rising
    // edge that commits the transfer.
    localparam time TA = ClkPeriod / 5;
    localparam time TT = (ClkPeriod * 4) / 5;
    // Every task that yields time leaves the simulation this far past a rising
    // edge, so that whatever the DUT registered on that edge has settled by the
    // time a check reads it.
    localparam time TPost = ClkPeriod / 10;

    // Register map
    localparam logic [31:0] MsipBase     = 32'h0000_0000;
    localparam logic [31:0] MtimecmpBase = 32'h0000_4000;
    localparam logic [31:0] MtimeLo      = 32'h0000_BFF8;
    localparam logic [31:0] TickTarget   = 32'h0000_C000;
    localparam logic [31:0] TickSource   = 32'h0000_C004;
    localparam logic [31:0] SetssipBase  = 32'h0001_0000;

    // Widest value either tick rate register can hold
    localparam logic [31:0] TickMax = 32'((64'd1 << TickW) - 64'd1);

    function automatic logic [31:0] msip_addr(input int unsigned h);
        return MsipBase + 32'd4 * h;
    endfunction

    function automatic logic [31:0] mtimecmp_addr(input int unsigned h);
        return MtimecmpBase + 32'd8 * h;
    endfunction

    function automatic logic [31:0] setssip_addr(input int unsigned h);
        return SetssipBase + 32'd4 * h;
    endfunction

    `REG_BUS_TYPEDEF_ALL(dut, logic [31:0], logic [31:0], logic [3:0])

    logic clk, rst_n;

    REG_BUS #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) reg_bus (clk);

    dut_req_t reg_req;
    dut_rsp_t reg_rsp;

    `REG_BUS_ASSIGN_TO_REQ(reg_req, reg_bus)
    `REG_BUS_ASSIGN_FROM_RSP(reg_bus, reg_rsp)

    logic [NumHarts-1:0] mtip, msip, ssip_set;
    logic [63:0]         mtime;

    aclint #(
        .NumHarts      ( NumHarts      ),
        .TickW         ( TickW         ),
        .DefaultTarget ( DefaultTarget ),
        .DefaultSource ( DefaultSource ),
        .reg_req_t     ( dut_req_t     ),
        .reg_rsp_t     ( dut_rsp_t     )
    ) i_dut (
        .clk_i      ( clk      ),
        .rst_ni     ( rst_n    ),
        .reg_req_i  ( reg_req  ),
        .reg_rsp_o  ( reg_rsp  ),
        .mtip_o     ( mtip     ),
        .msip_o     ( msip     ),
        .ssip_set_o ( ssip_set ),
        .mtime_o    ( mtime    )
    );

    initial begin
        clk = 1'b0;
        forever #(ClkPeriod / 2) clk = ~clk;
    end

    int unsigned checks = 0;
    int unsigned errors = 0;

    // ssip_set_o is a pulse, so it cannot be sampled by the bus tasks the way a
    // level output can. This monitor counts, per hart, how many cycles it was
    // asserted for.
    int unsigned ssip_cycles [NumHarts];
    int unsigned ssip_run     = 0;
    int unsigned ssip_max_run = 0;

    initial
        for (int unsigned h = 0; h < NumHarts; h++) ssip_cycles[h] = 0;

    // Blocking assignments are deliberate. This is an observer, and the checks
    // read these counters as plain variables rather than as sampled signals.
    /* verilator lint_off BLKSEQ */
    always @(negedge clk) begin
        if (rst_n) begin
            for (int unsigned h = 0; h < NumHarts; h++)
                if (ssip_set[h]) ssip_cycles[h]++;
            if (ssip_set != '0) begin
                ssip_run++;
                if (ssip_run > ssip_max_run) ssip_max_run = ssip_run;
            end else begin
                ssip_run = 0;
            end
        end
    end
    /* verilator lint_on BLKSEQ */

    task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("[FAIL] %s: got 0x%0h, expected 0x%0h", name, got, exp);
        end
    endtask

    // Advance n clock cycles and stop shortly after the last rising edge
    task automatic step(input int unsigned n = 1);
        repeat (n) @(posedge clk);
        #TPost;
    endtask

    /* verilator lint_off INITIALDLY */
    task automatic reset_master();
        reg_bus.addr  <= '0;
        reg_bus.write <= '0;
        reg_bus.wdata <= '0;
        reg_bus.wstrb <= '0;
        reg_bus.valid <= '0;
    endtask

    task automatic send_write(
        input  logic [31:0] addr,
        input  logic [31:0] data,
        input  logic [3:0]  strb,
        output logic        error
    );
        @(posedge clk);
        #TA;
        reg_bus.addr  <= addr;
        reg_bus.write <= 1'b1;
        reg_bus.wdata <= data;
        reg_bus.wstrb <= strb;
        reg_bus.valid <= 1'b1;
        #(TT - TA);
        while (reg_bus.ready !== 1'b1) begin
            @(posedge clk);
            #TT;
        end
        error = reg_bus.error;
        @(posedge clk);
        #TPost;
        reg_bus.addr  <= '0;
        reg_bus.write <= 1'b0;
        reg_bus.wdata <= '0;
        reg_bus.wstrb <= '0;
        reg_bus.valid <= 1'b0;
    endtask

    task automatic send_read(
        input  logic [31:0] addr,
        output logic [31:0] data,
        output logic        error
    );
        @(posedge clk);
        #TA;
        reg_bus.addr  <= addr;
        reg_bus.write <= 1'b0;
        reg_bus.valid <= 1'b1;
        #(TT - TA);
        while (reg_bus.ready !== 1'b1) begin
            @(posedge clk);
            #TT;
        end
        data  = reg_bus.rdata;
        error = reg_bus.error;
        @(posedge clk);
        #TPost;
        reg_bus.addr  <= '0;
        reg_bus.write <= 1'b0;
        reg_bus.valid <= 1'b0;
    endtask
    /* verilator lint_on INITIALDLY */

    // ----------------------------------------------------------------------
    // Checking wrappers around the driver
    // ----------------------------------------------------------------------
    task automatic reg_write(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [3:0]  strb = 4'hF
    );
        logic err;
        send_write(addr, data, strb, err);
        if (err) begin
            errors++;
            $display("[FAIL] unexpected error writing 0x%08h", addr);
        end
    endtask

    task automatic reg_read(input logic [31:0] addr, output logic [31:0] data);
        logic err;
        send_read(addr, data, err);
        if (err) begin
            errors++;
            $display("[FAIL] unexpected error reading 0x%08h", addr);
        end
    endtask

    task automatic expect_read(input string name, input logic [31:0] addr, input logic [31:0] exp);
        logic [31:0] data;
        reg_read(addr, data);
        chk(name, 64'(data), 64'(exp));
    endtask

    task automatic expect_error(input string name, input logic [31:0] addr);
        logic [31:0] rdata;
        logic        err;
        checks++;
        send_read(addr, rdata, err);
        if (!err) begin
            errors++;
            $display("[FAIL] %s: expected an error response at 0x%08h", name, addr);
        end
    endtask

    task automatic write64(input logic [31:0] lo_addr, input logic [63:0] data);
        reg_write(lo_addr,         data[31:0]);
        reg_write(lo_addr + 32'd4, data[63:32]);
    endtask

    task automatic read64(input logic [31:0] lo_addr, output logic [63:0] data);
        logic [31:0] lo, hi;
        reg_read(lo_addr,         lo);
        reg_read(lo_addr + 32'd4, hi);
        data = {hi, lo};
    endtask

    task automatic expect_read64(input string name, input logic [31:0] lo_addr, input logic [63:0] exp);
        logic [63:0] data;
        read64(lo_addr, data);
        chk(name, data, exp);
    endtask

    // A target rate of zero never lets the accumulator reach zero, so mtime stops advancing
    task automatic freeze_time();
        reg_write(TickTarget, 32'd0);
        step(2);
    endtask

    task automatic set_rate(input int unsigned target, input int unsigned source);
        reg_write(TickSource, source);
        reg_write(TickTarget, target);
        step(2);
    endtask

    task automatic clear_all_cmp();
        for (int unsigned h = 0; h < NumHarts; h++)
            write64(mtimecmp_addr(h), 64'hFFFF_FFFF_FFFF_FFFF);
        step();
    endtask

    // Count ticks over a window and compare against f_clk * target / source
    task automatic check_rate(
        input int unsigned target,
        input int unsigned source,
        input int unsigned window
    );
        logic [63:0] t0, t1;
        int          exp, got;
        set_rate(target, source);
        step();
        t0 = mtime;
        step(window);
        t1 = mtime;
        exp = int'((window * target) / source);
        got = int'(t1 - t0);
        checks++;
        if (got < exp - 1 || got > exp + 1) begin
            errors++;
            $display("[FAIL] rate %0d/%0d over %0d cycles: %0d ticks, expected %0d +/-1",
                     target, source, window, got, exp);
        end else begin
            $display("[ ok ] rate %0d/%0d over %0d cycles: %0d ticks (expected %0d)",
                     target, source, window, got, exp);
        end
    endtask

    initial begin
        logic [63:0] val64;
        logic        err;
        int unsigned ssip_before [NumHarts];
        int unsigned total_before, total_after;

        reset_master();
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        #TPost;
        rst_n = 1'b1;

        // ------------------------------------------------------------------
        // Reset state
        // ------------------------------------------------------------------
        step();
        chk("mtime out of reset",    mtime,         64'd0);
        chk("mtip out of reset",     64'(mtip),     64'd0);
        chk("msip out of reset",     64'(msip),     64'd0);
        chk("ssip_set out of reset", 64'(ssip_set), 64'd0);

        expect_read("ticksource default", TickSource, DefaultSource);
        expect_read("ticktarget default", TickTarget, DefaultTarget);

        freeze_time();

        for (int unsigned h = 0; h < NumHarts; h++) begin
            expect_read64($sformatf("mtimecmp[%0d] out of reset", h),
                          mtimecmp_addr(h), 64'hFFFF_FFFF_FFFF_FFFF);
            expect_read($sformatf("msip[%0d] out of reset", h), msip_addr(h), 32'd0);
        end

        // ------------------------------------------------------------------
        // MSWI: one MSIP register per hart, bit 0 only
        // ------------------------------------------------------------------
        for (int unsigned h = 0; h < NumHarts; h++) begin
            // Writing all ones must land in bit 0 alone
            reg_write(msip_addr(h), 32'hFFFF_FFFF);
            expect_read($sformatf("msip[%0d] set", h), msip_addr(h), 32'd1);
            chk($sformatf("msip_o[%0d] set", h), 64'(msip), 64'd1 << h);

            // msip lives in byte 0, so a strobe that misses it changes nothing
            reg_write(msip_addr(h), 32'h0000_0000, 4'b1110);
            expect_read($sformatf("msip[%0d] survives an unstrobed write", h),
                        msip_addr(h), 32'd1);

            reg_write(msip_addr(h), 32'hFFFF_FFFE);
            expect_read($sformatf("msip[%0d] cleared", h), msip_addr(h), 32'd0);
            chk($sformatf("msip_o[%0d] cleared", h), 64'(msip), 64'd0);
        end

        // All harts at once, to catch a decoder that aliases them
        for (int unsigned h = 0; h < NumHarts; h++) reg_write(msip_addr(h), 32'd1);
        chk("msip_o all set", 64'(msip), (64'd1 << NumHarts) - 64'd1);
        for (int unsigned h = 0; h < NumHarts; h++) reg_write(msip_addr(h), 32'd0);
        chk("msip_o all cleared", 64'(msip), 64'd0);

        // ------------------------------------------------------------------
        // SSWI: SETSSIP is set-only and reads back zero
        // ------------------------------------------------------------------
        for (int unsigned h = 0; h < NumHarts; h++) begin
            for (int unsigned k = 0; k < NumHarts; k++) ssip_before[k] = ssip_cycles[k];

            // Writing 1 raises the set request for exactly one cycle
            reg_write(setssip_addr(h), 32'd1);
            step(2);
            chk($sformatf("setssip[%0d] write of 1 sets once", h),
                64'(ssip_cycles[h]) - 64'(ssip_before[h]), 64'd1);
            for (int unsigned k = 0; k < NumHarts; k++)
                if (k != h)
                    chk($sformatf("setssip[%0d] left hart %0d alone", h, k),
                        64'(ssip_cycles[k]) - 64'(ssip_before[k]), 64'd0);

            // There is no pending bit to read back, so it stays zero
            expect_read($sformatf("setssip[%0d] reads zero after a set", h),
                        setssip_addr(h), 32'd0);

            // Writing 0 has no effect
            ssip_before[h] = ssip_cycles[h];
            reg_write(setssip_addr(h), 32'd0);
            step(2);
            chk($sformatf("setssip[%0d] write of 0 does nothing", h),
                64'(ssip_cycles[h]) - 64'(ssip_before[h]), 64'd0);

            // Only bit 0 is looked at
            ssip_before[h] = ssip_cycles[h];
            reg_write(setssip_addr(h), 32'hFFFF_FFFE);
            step(2);
            chk($sformatf("setssip[%0d] ignores bits above bit 0", h),
                64'(ssip_cycles[h]) - 64'(ssip_before[h]), 64'd0);

            ssip_before[h] = ssip_cycles[h];
            reg_write(setssip_addr(h), 32'hFFFF_FFFF);
            step(2);
            chk($sformatf("setssip[%0d] write of all ones sets", h),
                64'(ssip_cycles[h]) - 64'(ssip_before[h]), 64'd1);

            // A strobe that misses byte 0 cannot reach bit 0
            ssip_before[h] = ssip_cycles[h];
            reg_write(setssip_addr(h), 32'hFFFF_FFFF, 4'b1110);
            step(2);
            chk($sformatf("setssip[%0d] needs byte 0 strobed", h),
                64'(ssip_cycles[h]) - 64'(ssip_before[h]), 64'd0);
        end

        // Reading SETSSIP must not set anything
        total_before = 0;
        total_after  = 0;
        for (int unsigned k = 0; k < NumHarts; k++) total_before += ssip_cycles[k];
        for (int unsigned k = 0; k < NumHarts; k++)
            expect_read($sformatf("setssip[%0d] reads zero", k), setssip_addr(k), 32'd0);
        step(2);
        for (int unsigned k = 0; k < NumHarts; k++) total_after += ssip_cycles[k];
        chk("reading setssip raises nothing", 64'(total_after) - 64'(total_before), 64'd0);

        // SSWI and MSWI must not alias each other
        chk("msip untouched by the SSWI accesses", 64'(msip), 64'd0);

        // ------------------------------------------------------------------
        // MTIMER: MTIMECMP is per hart, MTIME is global
        // ------------------------------------------------------------------
        for (int unsigned h = 0; h < NumHarts; h++)
            write64(mtimecmp_addr(h), {32'h2000_0000 + h, 32'h1000_0000 + h});
        for (int unsigned h = 0; h < NumHarts; h++)
            expect_read64($sformatf("mtimecmp[%0d] readback", h), mtimecmp_addr(h),
                          {32'h2000_0000 + h, 32'h1000_0000 + h});

        // Partial write: only the strobed bytes move
        reg_write(mtimecmp_addr(TopHart), 32'hDEAD_BEEF, 4'b0011);
        expect_read64($sformatf("mtimecmp[%0d] byte strobed", TopHart), mtimecmp_addr(TopHart),
                      {32'h2000_0000 + TopHart, 32'h1000_BEEF});

        write64(MtimeLo, 64'h0000_0001_2345_6789);
        expect_read64("mtime readback", MtimeLo, 64'h0000_0001_2345_6789);
        chk("mtime_o matches the bus view", mtime, 64'h0000_0001_2345_6789);

        reg_write(MtimeLo, 32'hFFFF_FFFF, 4'b1000);
        expect_read64("mtime byte strobed", MtimeLo, 64'h0000_0001_FF45_6789);

        // ------------------------------------------------------------------
        // mtip is a level sensitive unsigned 64-bit compare
        // ------------------------------------------------------------------
        clear_all_cmp();
        write64(MtimeLo, 64'd0);
        write64(mtimecmp_addr(TestHart), 64'h0000_0000_0000_0100);

        write64(MtimeLo, 64'h0000_0000_0000_00FF);
        step();
        chk("mtip clear below mtimecmp", 64'(mtip), 64'd0);

        write64(MtimeLo, 64'h0000_0000_0000_0100);
        step();
        chk("mtip set at mtimecmp", 64'(mtip), 64'd1 << TestHart);

        write64(MtimeLo, 64'h0000_0000_0000_0101);
        step();
        chk("mtip stays set above mtimecmp", 64'(mtip), 64'd1 << TestHart);

        // Raising the compare is how software acknowledges the interrupt
        write64(mtimecmp_addr(TestHart), 64'h0000_0000_0000_0200);
        step();
        chk("mtip cleared by raising mtimecmp", 64'(mtip), 64'd0);

        // The compare has to carry across the low word
        clear_all_cmp();
        write64(mtimecmp_addr(0), 64'h0000_0000_FFFF_FFFF);
        write64(MtimeLo, 64'h0000_0000_FFFF_FFFE);
        step();
        chk("mtip clear one below a word boundary", 64'(mtip), 64'd0);
        write64(MtimeLo, 64'h0000_0001_0000_0000);
        step();
        chk("mtip set across the word boundary", 64'(mtip), 64'd1);

        // ------------------------------------------------------------------
        // Decode errors
        // ------------------------------------------------------------------
        expect_error("msip above NumHarts",      msip_addr(NumHarts));
        expect_error("MSWI reserved word",       32'h0000_3FFC);
        expect_error("mtimecmp above NumHarts",  mtimecmp_addr(NumHarts));
        expect_error("MTIMECMP region tail",     32'h0000_BFF0);
        expect_error("above the tick registers", 32'h0000_C008);
        expect_error("gap below the SSWI region", 32'h0000_FFFC);
        expect_error("setssip above NumHarts",   setssip_addr(NumHarts));
        expect_error("SSWI reserved word",       32'h0001_3FFC);
        expect_error("outside the region",       32'h0002_0000);

        // An erroring write must not land anywhere
        reg_write(TickSource, 32'd12);
        send_write(32'h0000_C008, 32'hDEAD_BEEF, 4'hF, err);
        chk("write to an unmapped address errors", 64'(err), 64'd1);
        expect_read("ticksource untouched by the errored write", TickSource, 32'd12);

        // ------------------------------------------------------------------
        // Tick rate registers
        // ------------------------------------------------------------------
        reg_write(TickTarget, 32'hFFFF_FFFF);
        expect_read("ticktarget truncated to TickW", TickTarget, TickMax);
        reg_write(TickSource, 32'hFFFF_FFFF);
        expect_read("ticksource truncated to TickW", TickSource, TickMax);

        reg_write(TickSource, 32'd0);
        reg_write(TickSource, 32'h0000_00AB, 4'b0001);
        expect_read("ticksource byte 0 strobe", TickSource, 32'h0000_00AB);
        reg_write(TickSource, 32'h00CD_0000, 4'b0100);
        expect_read("ticksource byte 2 strobe", TickSource, 32'h00CD_00AB);

        // ------------------------------------------------------------------
        // Fractional tick rate
        // ------------------------------------------------------------------
        freeze_time();
        write64(MtimeLo, 64'd0);
        clear_all_cmp();

        check_rate( 1,  4,  400);
        check_rate( 3,  8,  800);
        check_rate( 7, 11, 1100);
        check_rate(10, 33,  990);
        check_rate( 1,  1,  100);

        // mtime is a true 64-bit counter
        freeze_time();
        write64(MtimeLo, 64'h0000_0000_FFFF_FFF0);
        set_rate(1, 1);
        step(64);
        freeze_time();
        read64(MtimeLo, val64);
        checks++;
        if (val64 <= 64'h0000_0000_FFFF_FFFF) begin
            errors++;
            $display("[FAIL] mtime did not carry into the high word: 0x%016h", val64);
        end

        // A target rate of zero stops the counter outright
        freeze_time();
        step();
        val64 = mtime;
        step(32);
        chk("mtime frozen at target 0", mtime, val64);

        // Every ssip_set_o assertion over the whole run was a single cycle wide.
        // A zero here would mean the set path never fired at all.
        chk("ssip_set is always exactly one cycle", 64'(ssip_max_run), 64'd1);

        // ------------------------------------------------------------------
        $display("");
        if (errors == 0) $display("aclint_tb: PASS (%0d checks)", checks);
        else             $display("aclint_tb: FAIL (%0d of %0d checks failed)", errors, checks);
        $display("");

        if (errors != 0) $fatal(1, "aclint_tb: %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #2ms;
        $fatal(1, "aclint_tb: timeout");
    end

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("aclint_tb.vcd");
            $dumpvars(0, aclint_tb);
        end
    end

endmodule
