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
/// @notice 单个 V3 池子的「流动性挖矿记账本」：记录全局奖励累计值与各 tick 的挖矿流动性状态。
/// @dev 形象理解：核心池 `PancakeV3Pool` 负责“交易和价格移动”，本合约负责“把这段时间应发的挖矿奖励按活跃流动性记账”。
/// 典型链路：
/// 1) 交易发生时，池子会调用 `accumulateReward` 和 `crossLmTick`；
/// 2) 用户在 MasterChef 里增减仓时，MasterChef 调 `updatePosition` 同步区间流动性；
/// 3) MasterChef 通过 `getRewardGrowthInside` 读取区间累计值，计算用户待领取奖励。
contract PancakeV3LmPool is IPancakeV3LmPool {
  using LowGasSafeMath for uint256;
  using LowGasSafeMath for int256;
  using SafeCast for uint256;
  using SafeCast for int256;
  using LmTick for mapping(int24 => LmTick.Info);

  /// @notice 奖励精度缩放因子（与 MasterChef 的奖励单位对齐）。
  /// @dev 示例：若 MasterChef 的 `rewardPerSecond` 以 1e12 为精度，本常量用于把不同精度统一到同一套计算公式里。
  uint256 public constant REWARD_PRECISION = 1e12;

  /// @notice 对应的核心交易池（例如 USDT/WBNB 的某个 fee 档池子）。
  /// @dev 仅该池可调用 `crossLmTick`，并可与 MasterChef 一起调用 `accumulateReward`。
  IPancakeV3Pool public immutable pool;
  /// @notice 主挖矿合约地址（MasterChefV3）。
  /// @dev 仅 MasterChef 可调用 `updatePosition`，确保用户仓位变更只能由官方入口同步。
  IMasterChefV3 public immutable masterChef;

  /// @notice 全局每单位活跃挖矿流动性的奖励累计值（Q128.128 定点数）。
  /// @dev 示例：当它从 100 增长到 120，表示“每 1 单位活跃流动性”在这段时间新累计了 20 单位奖励份额。
  uint256 public rewardGrowthGlobalX128;

  /// @notice 挖矿 tick 状态表：记录每个初始化 tick 的流动性总量/净量，以及区间外奖励累计值。
  /// @dev 与 V3 核心池 `ticks` 概念一致，但这里是“挖矿奖励维度”的 tick 账本。
  mapping(int24 => LmTick.Info) public lmTicks;

  /// @notice 当前价格所在区间内的活跃挖矿流动性（可理解为 MasterChef 认可的加权后有效流动性）。
  /// @dev 示例：总质押很多，但当前价格只落在部分用户区间里，只有这部分会计入 `lmLiquidity` 参与当下奖励分配。
  uint128 public lmLiquidity;

  /// @notice 上次完成奖励累计的时间戳（单调递增）。
  /// @dev 每次 `accumulateReward` 都会把它更新到当前处理时间，避免同一时间段重复累计。
  uint32 public lastRewardTimestamp;

  /// @notice 仅核心池可调用（防止外部伪造跨 tick 事件）。
  modifier onlyPool() {
    require(msg.sender == address(pool), "Not pool");
    _;
  }

  /// @notice 仅 MasterChef 可调用（防止外部篡改仓位流动性账本）。
  modifier onlyMasterChef() {
    require(msg.sender == address(masterChef), "Not MC");
    _;
  }

  /// @notice 仅核心池或 MasterChef 可调用（奖励累计允许两侧触发）。
  modifier onlyPoolOrMasterChef() {
    require(msg.sender == address(pool) || msg.sender == address(masterChef), "Not pool or MC");
    _;
  }

  /// @notice 构造函数：绑定核心池、MasterChef，并设置奖励起算时间。
  /// @param _pool 对应的 V3 核心池地址（例如 USDT/WBNB 0.25% 池）。
  /// @param _masterChef MasterChefV3 地址（负责管理 NFT 质押与奖励发放）。
  /// @param rewardStartTimestamp 奖励累计起点时间。
  /// @dev 示例：若活动 10:00 开始，部署时传入 10:00，则 10:00 之前不会累计奖励增量。
  constructor(address _pool, address _masterChef, uint32 rewardStartTimestamp) {
    pool = IPancakeV3Pool(_pool);
    masterChef = IMasterChefV3(_masterChef);
    lastRewardTimestamp = rewardStartTimestamp;
  }

  /// @notice 按时间把 MasterChef 的排放速率累计到 `rewardGrowthGlobalX128`。
  /// @param currTimestamp 本次累计截止时间（通常为 `block.timestamp`）。
  /// @dev 使用场景：
  /// - 池子发生 swap 前先累计，保证“价格移动前的那段时间”奖励不会丢；
  /// - MasterChef 在用户操作前累计，保证用户结算时读到的是最新全局奖励账本。
  /// @dev 例子：`lastRewardTimestamp=100`，当前时间=130，`lmLiquidity>0`，
  /// 则会按 30 秒 * rewardPerSecond / 有效流动性 把这 30 秒奖励增量记入全局累计值。
  function accumulateReward(uint32 currTimestamp) external override onlyPoolOrMasterChef {
    // 若时间未前进，直接返回，避免重复累计同一时间段奖励。
    if (currTimestamp <= lastRewardTimestamp) {
      return;
    }

    // 只有存在活跃挖矿流动性时才累计；否则奖励“无承接者”，不做增长。
    if (lmLiquidity != 0) {
      // 从 MasterChef 读取当前池子的排放参数（每秒奖励、周期结束时间）。
      // 示例：读取到 rewardPerSecond=5e12，表示每秒发 5 个奖励单位（按 1e12 精度）。
      (uint256 rewardPerSecond, uint256 endTime) = masterChef.getLatestPeriodInfo(address(pool));

      // 将结束时间转换为 uint32（本地仅用于时间差计算）。
      uint32 endTimestamp = uint32(endTime);
      uint32 duration;
      // 当前实现按“当前时间 - 上次时间”累计。
      // 示例：上次 100，本次 130，则 duration=30 秒。
        duration = currTimestamp - lastRewardTimestamp;
      // 下面这组注释逻辑是历史思路：若超过活动结束时间，仅累计到 endTimestamp。
      // 当前代码未启用该分支，保持与线上既有行为一致。
      endTimestamp;

      // 持续时间不为 0 才有必要更新全局累计值。
      if (duration != 0) {
        // 核心公式（逐层解释）：
        // 1) rewardPerSecond / REWARD_PRECISION：把排放速率归一到统一精度；
        // 2) * Q128：转成定点数，便于高精度“每单位流动性”累计；
        // 3) * duration：得到该时间段总奖励；
        // 4) / lmLiquidity：分摊到“每单位活跃流动性”。
        // 结果累加到 rewardGrowthGlobalX128，供后续区间结算使用。
        rewardGrowthGlobalX128 += FullMath.mulDiv(duration, FullMath.mulDiv(rewardPerSecond, FixedPoint128.Q128, REWARD_PRECISION), lmLiquidity);
      }
    }

    // 不论是否累计成功，都推进“已处理时间”，防止下次重复处理这段区间。
    lastRewardTimestamp = currTimestamp;
  }

  /// @notice 当核心池价格跨过某个已初始化 tick 时，同步更新 LM 活跃流动性。
  /// @param tick 被跨越的 tick。
  /// @param zeroForOne 价格方向：`true` 为 token0->token1（价格向左），`false` 反之。
  /// @dev 使用场景：swap 过程中价格跨 tick，池子会调用本函数，保证“当前活跃挖矿流动性”与核心池有效区间一致。
  /// @dev 示例：价格从 tick 120 跨到 119，某区间刚好失活，则 `lmLiquidity` 会按 `liquidityNet` 减少。
  function crossLmTick(int24 tick, bool zeroForOne) external override onlyPool {
    // 该 tick 没有任何挖矿流动性记录时，无需处理。
    if (lmTicks[tick].liquidityGross == 0) {
      return;
    }

    // 计算跨越该 tick 后应施加的净流动性变化，同时刷新该 tick 的“区间外奖励累计值”。
    int128 lmLiquidityNet = lmTicks.cross(tick, rewardGrowthGlobalX128);

    // 与核心池规则一致：向左跨 tick 时净变化符号取反。
    if (zeroForOne) {
      lmLiquidityNet = -lmLiquidityNet;
    }

    // 把净变化应用到当前活跃挖矿流动性。
    lmLiquidity = LiquidityMath.addDelta(lmLiquidity, lmLiquidityNet);
  }

  /// @notice 新增/减少某仓位区间的挖矿流动性（仅 MasterChef 调用）。
  /// @param tickLower 仓位下边界 tick（含）。
  /// @param tickUpper 仓位上边界 tick（不含）。
  /// @param liquidityDelta 流动性变化量：正数=增加，负数=减少。
  /// @dev 使用场景：
  /// - 用户在 MasterChef 质押 NFT 时，MasterChef 传正数，登记可挖矿流动性；
  /// - 用户减仓/解押时，MasterChef 传负数，撤销对应挖矿流动性。
  /// @dev 示例：用户把 [100,200) 区间流动性 +1000 质押进 farm，MasterChef 调本函数后，
  /// 若当前价在该区间内，则 `lmLiquidity` 立刻 +1000。
  function updatePosition(int24 tickLower, int24 tickUpper, int128 liquidityDelta) external onlyMasterChef {
    // 读取核心池当前 tick；用于判断该仓位是否“当前活跃”。
    (, int24 tick, , , , ,) = pool.slot0();
    // 读取每个 tick 允许的最大流动性，避免超上限写入。
    uint128 maxLiquidityPerTick = pool.maxLiquidityPerTick();
    // 缓存全局奖励累计值，避免重复 SLOAD。
    uint256 _rewardGrowthGlobalX128 = rewardGrowthGlobalX128;

    bool flippedLower;
    bool flippedUpper;
    // 仅在确有变动时更新上下边界 tick 的账本。
    if (liquidityDelta != 0) {
      // 更新下边界：记录流动性变化与边界外奖励基准。
      flippedLower = lmTicks.update(
        tickLower,
        tick,
        liquidityDelta,
        _rewardGrowthGlobalX128,
        false,
        maxLiquidityPerTick
      );
      // 更新上边界：与下边界类似，但 upper=true 处理方向差异。
      flippedUpper = lmTicks.update(
        tickUpper,
        tick,
        liquidityDelta,
        _rewardGrowthGlobalX128,
        true,
        maxLiquidityPerTick
      );
    }

    // 若当前价格落在 [tickLower, tickUpper) 内，这次增减会立即影响“活跃挖矿流动性”。
    // 示例：当前 tick=150，用户改动区间 [100,200)，则立刻生效；若区间在远处则仅记账，等未来跨入才生效。
    if (tick >= tickLower && tick < tickUpper) {
      lmLiquidity = LiquidityMath.addDelta(lmLiquidity, liquidityDelta);
    }

    // 减仓时，如果某边界从“有流动性”翻转为“无流动性”，可清理该 tick 节省后续 gas。
    if (liquidityDelta < 0) {
      if (flippedLower) {
        lmTicks.clear(tickLower);
      }
      if (flippedUpper) {
        lmTicks.clear(tickUpper);
      }
    }
  }

  /// @notice 读取区间 `(tickLower, tickUpper)` 的“区间内奖励累计值”。
  /// @param tickLower 仓位下边界 tick。
  /// @param tickUpper 仓位上边界 tick。
  /// @return rewardGrowthInsideX128 区间内累计奖励增长（Q128.128）。
  /// @dev 使用场景：MasterChef 结算用户待领取奖励时，读取该值与用户上次快照做差，乘以用户有效流动性得到新增奖励。
  /// @dev 示例：用户上次快照是 100，本次读到 130，且有效流动性为 500，
  /// 则新增奖励与 (130-100)*500 成正比（具体除法精度由 MasterChef 处理）。
  function getRewardGrowthInside(int24 tickLower, int24 tickUpper) external view returns (uint256 rewardGrowthInsideX128) {
    // 读取当前价所在 tick，用于判断区间内/外并计算 inside 累计值。
    (, int24 tick, , , , ,) = pool.slot0();
    return lmTicks.getRewardGrowthInside(tickLower, tickUpper, tick, rewardGrowthGlobalX128);
  }
}
