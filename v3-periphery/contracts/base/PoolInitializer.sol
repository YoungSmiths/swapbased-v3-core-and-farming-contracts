// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Factory.sol';
import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol';

import './PeripheryImmutableState.sol';
import '../interfaces/IPoolInitializer.sol';

/// @title PoolInitializer —— 创建并初始化 V3 池（若尚未存在或未定价）
/// @notice 保证 `mint` / `swap` 前池子存在且 `slot0.sqrtPriceX96` 非零；否则首笔交易会失败。
///
/// **核心逻辑**：`token0 < token1` 排序；`getPool` 非空则复用；若新建池则 `createPool` 后 `initialize`；若池存在但价格为 0 则仅 `initialize`。
///
/// **使用场景**：上新交易对时先调此函数设定初始价格（`sqrtPriceX96` 对应初始汇率），再让用户加流动性或交易。
/// **实际案例**：部署 USDT/BNB 池，用当前价算出 `sqrtPriceX96`，一次交易完成「创建池 + 定价」。
abstract contract PoolInitializer is IPoolInitializer, PeripheryImmutableState {
    /// @notice 若池不存在则创建；若存在但未初始化价格则初始化。
    /// @param token0 排序后较小地址（必须 < token1）。
    /// @param token1 较大地址。
    /// @param fee 费率档（如 500、2500、10000）。
    /// @param sqrtPriceX96 初始价格的「平方根 × 2^96」表示（与核心池一致）。
    /// @return pool 池合约地址。
    /// @inheritdoc IPoolInitializer
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable override returns (address pool) {
        require(token0 < token1);
        pool = IPancakeV3Factory(factory).getPool(token0, token1, fee);

        if (pool == address(0)) {
            pool = IPancakeV3Factory(factory).createPool(token0, token1, fee);
            IPancakeV3Pool(pool).initialize(sqrtPriceX96);
        } else {
            (uint160 sqrtPriceX96Existing, , , , , , ) = IPancakeV3Pool(pool).slot0();
            if (sqrtPriceX96Existing == 0) {
                IPancakeV3Pool(pool).initialize(sqrtPriceX96);
            }
        }
    }
}
