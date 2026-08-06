# RISC-V Advanced Core Local Interruptor (ACLINT) with Fractional Timer

The repository contains a RISC-V Advanced Core Local Interruptor, [specification Version 1.0-rc4 (stable)](https://github.com/riscvarchive/riscv-aclint/releases/tag/v1.0-rc4).

The ACLINT plugs into a [generic register interface](https://github.com/pulp-platform/register_interface), which may be adapted to various protocols including AMBA APB and AXI 4/Lite (see repository for adapter IPs).

The `mtime` counter is driven by a fractional tick generator, so the timebase can be derived from any clock frequency without an integer divider and without long-term drift.

## Register map

The specification defines MSWI, MTIMER and SSWI as separately placeable devices. This IP exposes all three through a single register port. The whole map spans 128 KiB. Offsets are relative to the base the interconnect assigns to the device.

| Offset          | Bytes | Access | Register      | Device         |
| --------------- | ----- | ------ | ------------- | -------------- |
| `0x00000 + 4*h` | 4     | RW     | `MSIP[h]`     | MSWI           |
| `0x03FFC`       | 4     | -      | reserved      | MSWI           |
| `0x04000 + 8*h` | 8     | RW     | `MTIMECMP[h]` | MTIMER         |
| `0x0BFF8`       | 8     | RW     | `MTIME`       | MTIMER         |
| `0x0C000`       | 4     | RW     | `TICKTARGET`  | tick generator |
| `0x0C004`       | 4     | RW     | `TICKSOURCE`  | tick generator |
| `0x10000 + 4*h` | 4     | W      | `SETSSIP[h]`  | SSWI           |
| `0x13FFC`       | 4     | -      | reserved      | SSWI           |

`h` is a hart index in `0 .. NumHarts-1`. The two tick generator registers are an extension of this IP and sit in the gap the specification leaves after `MTIME`.

- **`MSIP[h]`** - machine software interrupt pending for hart `h`. Only bit 0 is implemented, the upper 31 bits read as zero and ignore writes. Writing 1 raises `msip_o[h]`, writing 0 lowers it.
- **`MTIMECMP[h]`** - machine timer compare for hart `h`. `mtip_o[h]` is asserted while `MTIME >= MTIMECMP[h]`, as an unsigned 64-bit comparison. Resets to all ones so no timer interrupt is pending out of reset.
- **`MTIME`** - the global 64-bit time counter, shared by all harts and mirrored on `mtime_o` for `rdtime`/`rdtimeh`. A write takes priority over an increment.
- **`TICKTARGET`, `TICKSOURCE`** - the tick generator rates, `TickW` bits wide each. Bits above `TickW` read as zero and ignore writes. Writing either register reloads the accumulator.
- **`SETSSIP[h]`** - supervisor software interrupt set for hart `h`. Writing 1 to bit 0 pulses `ssip_set_o[h]` for one cycle. Writing 0 does nothing, and bits above bit 0 are ignored. Reads return zero.

Accesses are decoded at word granularity: the two low address bits are ignored and byte lanes come from `wstrb`, which is how the upstream bus adapters present sub-word accesses. Reads and writes complete with zero wait states, `ready` is always high.

An access that lands outside the map, or on a hart index at or above `NumHarts`, is answered with `error` and commits nothing. Reads that error return zero.

## Supervisor software interrupts

`SETSSIP` is set-only: writing 1 raises the interrupt, writing 0 has no effect, and reads return zero. The specification gives the SSWI device no way to lower the interrupt, because the pending state does not live there, it lives in the hart's `sip.SSIP`, which supervisor software clears itself.

## Fractional tick generator

`mtime` increments on a tick whose average rate is

```text
f_tick = f_clk * TICKTARGET / TICKSOURCE
```

The generator is a signed accumulator, one add per clock, no divider or multiplier:

```text
tick = (acc >= 0)
acc += tick ? (target - source) : target
```

Over `N` cycles the accumulator's net change is `N*target - ticks*source`. It is bounded by construction, so `ticks` converges on `N*target/source`: the rate is exact in the long run and jitter never exceeds one clock period. Since only the ratio matters, `10`/`33` and `10_000_000`/`33_000_000` produce the same 10 MHz timebase from a 33 MHz clock; the smaller pair leaves more headroom in `TickW`.

Setting `TICKTARGET` to zero holds the accumulator negative, which stops `mtime` without stopping the clock.

## Parameters

`aclint`:

| Parameter       | Default                     | Notes                                         |
| --------------- | --------------------------- | --------------------------------------------- |
| `NumHarts`      | 1                           | 1 to 4095                                     |
| `TickW`         | 26                          | 1 to 32, width of each tick rate register     |
| `DefaultTarget` | 1                           | `TICKTARGET` reset value, must fit in `TickW` |
| `DefaultSource` | 1                           | `TICKSOURCE` reset value, must fit in `TickW` |
| `reg_req_t`     | `aclint_reg_pkg::..._req_t` | register bus request type                     |
| `reg_rsp_t`     | `aclint_reg_pkg::..._rsp_t` | register bus response type                    |
| `AW`            | 32                          | 17 to 32, the map spans 128 KiB               |
| `DW`            | 32                          | 32 only                                       |

Parameters are range-checked at elaboration outside of synthesis.

`aclint_reg_pkg` provides default request and response types matching `REG_BUS_TYPEDEF_ALL` from `register_interface`; override `reg_req_t`/`reg_rsp_t` to use your own.

## Ports

| Port         | Direction | Width       | Notes                                      |
| ------------ | --------- | ----------- | ------------------------------------------ |
| `clk_i`      | in        | 1           |                                            |
| `rst_ni`     | in        | 1           | asynchronous, active low                   |
| `reg_req_i`  | in        | `reg_req_t` |                                            |
| `reg_rsp_o`  | out       | `reg_rsp_t` |                                            |
| `mtip_o`     | out       | `NumHarts`  | machine timer interrupt pending, level     |
| `msip_o`     | out       | `NumHarts`  | machine software interrupt pending, level  |
| `ssip_set_o` | out       | `NumHarts`  | supervisor software interrupt set, 1 cycle |
| `mtime_o`    | out       | 64          | for `rdtime`/`rdtimeh`                     |

`mtip_o` is registered, so it follows a change in `MTIME` or `MTIMECMP` one cycle later. `ssip_set_o` is a pulse, not a level.

## Source files

| File                    | Contents                                                   |
| ----------------------- | ---------------------------------------------------------- |
| `src/aclint.sv`         | top level, register bus structs to flat signals            |
| `src/aclint_flat.sv`    | address decode, tick rate registers, submodule instances   |
| `src/aclint_core.sv`    | `mtime`, `mtimecmp`, `msip`, `setssip` and the comparators |
| `src/frac_tick.sv`      | fractional tick generator                                  |
| `src/aclint_reg_pkg.sv` | default register bus types                                 |

`aclint_flat` is usable directly if you would rather not carry the struct types.

## Not implemented

- Multiple `MTIME` domains. One counter serves every hart, which is the common single-clock-domain case.
- Placing MSWI, MTIMER and SSWI at unrelated base addresses. The specification allows it, this IP has a single register port, so the three devices share one contiguous map at fixed relative offsets.

## Simulation

Requires [Verilator](https://verilator.org) 5 and, for the testbench, [Bender](https://github.com/pulp-platform/bender): the testbench drives the DUT over a `REG_BUS` interface, and the Makefile asks Bender where the `register_interface` checkout is. Linting needs neither.

```sh
make lint          # lint the RTL at -Wall
make sim           # build and run the testbench
make regression    # re-run the testbench for hart counts 1, 2, 3, 4, 7
```

`build/aclint_tb +vcd` writes a waveform dump.

`make sources.f` regenerates the Bender file list for integration into a larger project.

## Editor setup

`.slang/server.json` configures the [slang language server](https://github.com/hudson-trading/slang-server) for in-editor diagnostics. It reads a file list that has to be generated first:

```sh
bender checkout && make ide
```

Re-run `make ide` after changing `Bender.yml` or `Bender.lock`.
