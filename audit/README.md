# BOXA launch contracts for audit

Chain: Elysium (chain ID 99901). Gas token: HYPE.

## Deployed contracts

| Contract | Address | Source |
| --- | --- | --- |
| BoxaUniLauncher | `0xF3Bae49a2019Ab9dcFd43Fe7B11c6f01340209C5` | `BoxaUniLauncher.sol` |
| BoxaUniHook | `0x00C002Cdae688F39a90CF2AD74c59421C9502aCC` | `BoxaUniHook.sol` |

## Supporting source files

- `BoxaFeeSplit.sol`: a fee-split library compiled into the hook. It has no address of its own.
- `BoxaV4Token.sol`: the ERC-20 that the launcher creates for each launch.

## External addresses these contracts use

- Uniswap v4 PoolManager (official, on Elysium): `0xe2e105d3f7209a9da11f83ccf3e7398a753823f1`
- Treasury: `0x4E496d24AA8fe7E026163C481DF726e9dc70b433`. It is immutable.
- WHYPE: `0xbA876237B0F021A6c6D852d6c26E107997cC5E81`

## Build settings

- Compiler: Solidity 0.8.26
- Optimizer: on, 200 runs
- viaIR: true
- EVM version: cancun

Dependencies, not included here:

- Uniswap `v4-core`
- Uniswap `v4-periphery` (only `LiquidityAmounts`)
- solmate (`ERC20` and `SafeTransferLib`)

Both deployed contracts were compiled from these files and compared with the code on chain. They match exactly, including the metadata hash.
