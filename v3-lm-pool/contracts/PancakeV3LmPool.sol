// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '@pancakeswap/v3-core/contracts/libraries/LowGasSafeMath.sol';
import '@pancakeswap/v3-core/contracts/libraries/SafeCast.sol';
import '@pancakeswap/v3-core/contracts/libraries/FullMath.sol';
import '@pancakeswap/v3-core/contracts/libraries/FixedPoint128.sol';
import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol';
import '@pancakeswap/v3-core/contracts/libraries/LiquidityMath.sol';

import './libraries/LmTick.sol';

import './interfaces/IPancakeV3LmPool.sol';
import './interfaces/IMasterChefV3.sol';

/// @title PancakeV3LmPool
/// @notice Liquidity-mining ledger for a single V3 pool: tracks `rewardGrowthGlobal` and per-tick LM state, analogous to swap fees but for emissions.
/// @dev The canonical pool calls `accumulateReward` / `crossLmTick` during swaps; MasterChef calls `updatePosition` when users stake or adjust boosted liquidity.
contract PancakeV3LmPool is IPancakeV3LmPool {
  using LowGasSafeMath for uint256;
  using LowGasSafeMath for int256;
  using SafeCast for uint256;
  using SafeCast for int256;
  using LmTick for mapping(int24 => LmTick.Info);

  /// @notice Scaling helper for emission rate math (matches MasterChef emission units).
  uint256 public constant REWARD_PRECISION = 1e12;

  IPancakeV3Pool public immutable pool;
  IMasterChefV3 public immutable masterChef;

  /// @notice Global reward accumulator per unit of active LM liquidity (Q128.128 fixed point).
  uint256 public rewardGrowthGlobalX128;

  /// @notice LM tick bitmap: gross/net liquidity and outside reward growth for farming, per initialized tick.
  mapping(int24 => LmTick.Info) public lmTicks;

  /// @notice Active LM liquidity at the current pool tick (boost-weighted stake from MasterChef).
  uint128 public lmLiquidity;

  /// @notice Last block timestamp processed by `accumulateReward` (monotonic).
  uint32 public lastRewardTimestamp;

  modifier onlyPool() {
    require(msg.sender == address(pool), "Not pool");
    _;
  }

  modifier onlyMasterChef() {
    require(msg.sender == address(masterChef), "Not MC");
    _;
  }

  modifier onlyPoolOrMasterChef() {
    require(msg.sender == address(pool) || msg.sender == address(masterChef), "Not pool or MC");
    _;
  }

  constructor(address _pool, address _masterChef, uint32 rewardStartTimestamp) {
    pool = IPancakeV3Pool(_pool);
    masterChef = IMasterChefV3(_masterChef);
    lastRewardTimestamp = rewardStartTimestamp;
  }

  /// @notice Distributes emissions from the MasterChef emission schedule into `rewardGrowthGlobalX128` over elapsed time.
  /// @param currTimestamp Block timestamp used as the accrual endpoint (typically `block.timestamp`).
  function accumulateReward(uint32 currTimestamp) external override onlyPoolOrMasterChef {
    if (currTimestamp <= lastRewardTimestamp) {
      return;
    }

    if (lmLiquidity != 0) {
      (uint256 rewardPerSecond, uint256 endTime) = masterChef.getLatestPeriodInfo(address(pool));

      uint32 endTimestamp = uint32(endTime);
      uint32 duration;
      // if (endTimestamp > currTimestamp) {
        duration = currTimestamp - lastRewardTimestamp;
      // } else if (endTimestamp > lastRewardTimestamp) {
      //   duration = endTimestamp - lastRewardTimestamp;
      // }

      if (duration != 0) {
        rewardGrowthGlobalX128 += FullMath.mulDiv(duration, FullMath.mulDiv(rewardPerSecond, FixedPoint128.Q128, REWARD_PRECISION), lmLiquidity);
      }
    }

    lastRewardTimestamp = currTimestamp;
  }

  /// @notice Invoked when the pool price crosses an initialized tick; updates LM liquidity net exactly like the core pool.
  function crossLmTick(int24 tick, bool zeroForOne) external override onlyPool {
    if (lmTicks[tick].liquidityGross == 0) {
      return;
    }

    int128 lmLiquidityNet = lmTicks.cross(tick, rewardGrowthGlobalX128);

    if (zeroForOne) {
      lmLiquidityNet = -lmLiquidityNet;
    }

    lmLiquidity = LiquidityMath.addDelta(lmLiquidity, lmLiquidityNet);
  }

  /// @notice Adds or removes boosted stake liquidity for a position’s tick range; only MasterChef after NFT custody.
  function updatePosition(int24 tickLower, int24 tickUpper, int128 liquidityDelta) external onlyMasterChef {
    (, int24 tick, , , , ,) = pool.slot0();
    uint128 maxLiquidityPerTick = pool.maxLiquidityPerTick();
    uint256 _rewardGrowthGlobalX128 = rewardGrowthGlobalX128;

    bool flippedLower;
    bool flippedUpper;
    if (liquidityDelta != 0) {
      flippedLower = lmTicks.update(
        tickLower,
        tick,
        liquidityDelta,
        _rewardGrowthGlobalX128,
        false,
        maxLiquidityPerTick
      );
      flippedUpper = lmTicks.update(
        tickUpper,
        tick,
        liquidityDelta,
        _rewardGrowthGlobalX128,
        true,
        maxLiquidityPerTick
      );
    }

    if (tick >= tickLower && tick < tickUpper) {
      lmLiquidity = LiquidityMath.addDelta(lmLiquidity, liquidityDelta);
    }

    if (liquidityDelta < 0) {
      if (flippedLower) {
        lmTicks.clear(tickLower);
      }
      if (flippedUpper) {
        lmTicks.clear(tickUpper);
      }
    }
  }

  /// @notice Reward growth inside `(tickLower, tickUpper)` at the current price; used for pending reward math on MasterChef.
  function getRewardGrowthInside(int24 tickLower, int24 tickUpper) external view returns (uint256 rewardGrowthInsideX128) {
    (, int24 tick, , , , ,) = pool.slot0();
    return lmTicks.getRewardGrowthInside(tickLower, tickUpper, tick, rewardGrowthGlobalX128);
  }
}
