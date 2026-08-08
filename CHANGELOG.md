# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-08-06

### Fixed

- Reset the tick accumulator to a constant.
- Stop the accumulator running away when `TICKSOURCE` is zero. A zero source now holds `MTIME` the way a zero target and ticking on the way up.

### Changed

- Initialize the testbench's pulse monitor counters in an `initial` block, so the testbench builds under Verilator's `PROCASSINIT` check.

## [0.1.0] - 2026-08-06 [YANKED]

### Changed

- YANKED because of a critical reset bug making it unsafe outside of simulation.
- Lint fix.

### Added

- Add initial module.
- Add basic testbench.
- Add CI.
