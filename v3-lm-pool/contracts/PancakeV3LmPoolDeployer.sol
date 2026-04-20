// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Factory.sol';
import '@pancakeswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';

import './PancakeV3LmPool.sol';

/// @title PancakeV3LmPoolDeployer
/// @notice LM 池部署器：当 MasterChef 为某个 V3 池开通挖矿时，负责创建对应 `PancakeV3LmPool` 并绑定到核心池。
/// @dev 为什么单独拆一个合约：
/// - `PancakeV3LmPool` 使用 Solidity 0.7.6；
/// - MasterChefV3 常在 0.8.x；
/// - 拆分后可避免版本混编复杂度，同时把部署权限收敛到一个最小职责合约。
contract PancakeV3LmPoolDeployer {
    /// @notice 唯一授权调用者（MasterChefV3）。
    /// @dev 只有它能触发 `deploy`，防止任意地址给池子乱绑 LM 合约。
    address public immutable masterChef;

    /// @notice 仅 MasterChef 可调用。
    modifier onlyMasterChef() {
        require(msg.sender == masterChef, "Not MC");
        _;
    }

    /// @notice 构造函数：记录 MasterChef 地址。
    /// @param _masterChef MasterChefV3 合约地址。
    /// @dev 使用场景：部署脚本先部署 MasterChef，再把其地址传进本合约完成绑定。
    constructor(address _masterChef) {
        masterChef = _masterChef;
    }

    /// @notice 为指定 V3 池部署一个新的 LM 池，并注册到 Factory，使核心池在 swap 时会调用 LM 记账钩子。
    /// @param pool 目标核心池地址（例如 USDT/WBNB 0.25% 池）。
    /// @return lmPool 新部署的 LM 池地址。
    /// @dev 使用场景：MasterChef 新增某个 V3 池的挖矿计划时调用本函数，一次性完成“创建 + 绑定”。
    /// @dev 实际案例：
    /// - 运营新增 `WBNB/USDT` v3 农场；
    /// - MasterChef 调用 `deploy(pool)`；
    /// - 之后该池每次 swap 都会同步更新 LM 奖励累计，不会漏记交易期间的挖矿时间。
    function deploy(IPancakeV3Pool pool) external onlyMasterChef returns (IPancakeV3LmPool lmPool) {
        // 1) 部署该池专属的 LM 记账合约。
        // 第三个参数传当前时间，表示“从现在开始累计奖励时间轴”。
        lmPool = new PancakeV3LmPool(address(pool), masterChef, uint32(block.timestamp));
        // 2) 通过 PositionManager 找到对应 Factory，并把 lmPool 绑定进核心池。
        // 绑定成功后，核心池 swap 时会调用 LM 侧车：
        // - accumulateReward：累计全局奖励
        // - crossLmTick：跨 tick 同步活跃挖矿流动性
        IPancakeV3Factory(INonfungiblePositionManager(IMasterChefV3(masterChef).nonfungiblePositionManager()).factory()).setLmPool(address(pool), address(lmPool));
    }
}
