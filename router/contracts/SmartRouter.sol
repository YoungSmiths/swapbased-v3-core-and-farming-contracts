// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@pancakeswap/v3-periphery/contracts/base/SelfPermit.sol';
import '@pancakeswap/v3-periphery/contracts/base/PeripheryImmutableState.sol';

import './interfaces/ISmartRouter.sol';
import './V2SwapRouter.sol';
import './V3SwapRouter.sol';
import './StableSwapRouter.sol';
import './base/ApproveAndCall.sol';
import './base/MulticallExtended.sol';

/// @title 智能路由（聚合入口）
/// @notice 将 V2 兑换、V3 兑换、稳定币曲线池、Permit 签名授权、批量 multicall 等能力合并到一个部署地址，前端/DApp 只需对接本合约即可按路径选择不同底层。
/// @dev 继承带来的「不可变状态」一览（便于对照构造函数入参）：
/// - `factoryV2`、`positionManager`：来自 `ImmutableState`，用于 V2 找 Pair、与 NFT 头寸管理器协同等场景。
/// - `deployer`、`factory`、`WETH9`：来自 `PeripheryImmutableState`（V3 外围标准），用于按 (token0,token1,fee) 解析 V3 池地址、原生币包装 ETH。
/// - `stableSwapFactory`、`stableSwapInfo`：来自 `StableSwapRouter`，用于稳定池路径解析与询价。
/// 使用场景举例：产品希望「同一合约地址」同时暴露 `swapExactTokensForTokens`（V2）、`exactInput`（V3）、`exactInputStableSwap`（稳定池），并支持 `multicall` 把「approve+swap」打包成一笔交易。
contract SmartRouter is ISmartRouter, V2SwapRouter, V3SwapRouter, StableSwapRouter, ApproveAndCall, MulticallExtended, SelfPermit {
    /// @notice 部署时一次性写入所有底层协议地址，之后不可改（稳定池 factory/info 可由 owner 在 `StableSwapRouter` 中更新）。
    /// @param _factoryV2 Pancake/Uniswap V2 风格工厂，例：链上已部署的 `UniswapV2Factory`，用于 `pairFor` 计算交易对地址。
    /// @param _deployer V3 池部署器（CREATE2 盐与 Pancake 实现一致），用于从 (tokenA, tokenB, fee) 推导池合约地址。
    /// @param _factoryV3 V3 工厂主合约，与 `PeripheryImmutableState` 标准一致。
    /// @param _positionManager NonfungiblePositionManager，与 V2 路由里「添加流动性」等外围流程对齐。
    /// @param _stableFactory 稳定币交换工厂，例如管理 USDT-BUSD-USDC 三池的工厂合约地址。
    /// @param _stableInfo 稳定池元数据/索引合约，配合 factory 做路径解析与 `exactOutput` 询价。
    /// @param _WETH9 包装 ETH 地址；用户用 ETH 交易时 often 先 wrap 成 WETH 再 swap。
    constructor(
        address _factoryV2,
        address _deployer,
        address _factoryV3,
        address _positionManager,
        address _stableFactory,
        address _stableInfo,
        address _WETH9
    ) ImmutableState(_factoryV2, _positionManager) PeripheryImmutableState(_deployer, _factoryV3, _WETH9) StableSwapRouter(_stableFactory, _stableInfo) {}
}
