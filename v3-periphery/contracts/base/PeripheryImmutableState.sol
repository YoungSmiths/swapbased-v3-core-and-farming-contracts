// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '../interfaces/IPeripheryImmutableState.sol';

/// @title PeripheryImmutableState —— 外围合约的不可变全局配置
/// @notice 部署时写入，**不可升级**；池地址计算、WETH 支付、回调校验都依赖这三项。
///
/// **形象理解**：工厂做「池子在哪」、deployer 做「CREATE2 盐」、WETH9 做「ETH 与 ERC20 统一支付」。
abstract contract PeripheryImmutableState is IPeripheryImmutableState {
    /// @notice V3 池的 CREATE2 部署者（与 `PoolAddress.computeAddress`、mint 回调校验一致）。
    address public immutable override deployer;
    /// @notice Pancake V3 `Factory`，用于 `getPool` / `createPool`。
    address public immutable override factory;
    /// @notice 链上 WETH9；合约 `receive` 仅允许 WETH 合约打 ETH，unwrap 时把 WETH 变 ETH 转出。
    address public immutable override WETH9;

    /// @param _deployer 池部署者地址。
    /// @param _factory V3 工厂合约。
    /// @param _WETH9 包 ETH 的 WETH 合约地址。
    constructor(address _deployer, address _factory, address _WETH9) {
        deployer = _deployer;
        factory = _factory;
        WETH9 = _WETH9;
    }
}
