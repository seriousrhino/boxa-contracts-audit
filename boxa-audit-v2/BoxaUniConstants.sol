// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

/// @dev Values the V2 hook, launcher and token must agree on, kept in one place.

/// @dev Total supply of every launch token, in wei.
uint256 constant BOXA_SUPPLY = 1_000_000_000 ether;
/// @dev Where burned tokens go. It never earns holder rewards.
address constant BOXA_DEAD = 0x000000000000000000000000000000000000dEaD;
/// @dev Tick spacing of every launch pool.
int24 constant BOXA_TICK_SPACING = 200;
