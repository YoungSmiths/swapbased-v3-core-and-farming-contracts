// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@pancakeswap/v3-core/contracts/libraries/LowGasSafeMath.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';

import './interfaces/INonfungiblePositionManager.sol';

import './libraries/TransferHelper.sol';

import './interfaces/IV3Migrator.sol';
import './base/PeripheryImmutableState.sol';
import './base/Multicall.sol';
import './base/SelfPermit.sol';
import './interfaces/external/IWETH9.sol';
import './base/PoolInitializer.sol';

/// @title V3Migrator
/// @notice V2 -> V3 迁移器：把 V2 LP 头寸拆出 token，再按指定区间铸造成 V3 NFT 仓位。
/// @dev 使用场景：
/// - 用户已持有 V2 Pair LP，想迁移到 V3 集中流动性；
/// - 前端一键迁移：授权 V2 LP 后调用 `migrate`。
contract V3Migrator is IV3Migrator, PeripheryImmutableState, PoolInitializer, Multicall, SelfPermit {
    using LowGasSafeMath for uint256;

    /// @notice V3 仓位管理器（NPM）地址，用于调用 `mint` 铸造 V3 NFT 仓位。
    address public immutable nonfungiblePositionManager;

    /// @notice 构造函数：注入 deployer/factory/WETH9/NPM。
    /// @dev `PeripheryImmutableState` 会保存 deployer/factory/WETH9，迁移时用于支付和 ETH/WETH 退款逻辑。
    constructor(
        address _deployer,
        address _factory,
        address _WETH9,
        address _nonfungiblePositionManager
    ) PeripheryImmutableState(_deployer, _factory, _WETH9) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
    }

    /// @notice 仅接收 WETH9 解包后回流的 ETH。
    /// @dev 防止其他地址误转 ETH 到合约。
    receive() external payable {
        require(msg.sender == WETH9, 'Not WETH9');
    }

    /// @notice 把用户的 V2 LP（全部或按比例）迁移成 V3 仓位 NFT。
    /// @param params 迁移参数（pair、token0/token1、fee、tick 区间、最小接收、比例、接收人等）。
    /// @dev 使用场景：
    /// - 你持有 10 枚 V2 LP，只想迁移 60% 到 V3；
    /// - 设置目标 V3 区间（tickLower/tickUpper）后执行；
    /// - 未用完的 token 会退回（可选 WETH 退成 ETH）。
    /// @dev 核心逻辑（逐行）：
    /// 1) 校验迁移比例；
    /// 2) 把 V2 LP 转给 Pair 并 `burn`，拿到底层 token0/token1；
    /// 3) 按比例计算本次迁移金额；
    /// 4) 授权 NPM 并铸造 V3 仓位；
    /// 5) 清理多余授权并退回剩余 token（支持 WETH->ETH 退款）。
    /// @dev 实际案例：
    /// 用户迁移 WBNB/USDT V2 LP，burn 后得到 1 WBNB + 3000 USDT；
    /// 若 `percentageToMigrate=50`，则只拿 0.5 WBNB + 1500 USDT 去 mint V3，
    /// 其余资产退回用户钱包。
    function migrate(MigrateParams calldata params) external override {
        // 比例必须在 (0, 100]。
        require(params.percentageToMigrate > 0, 'Percentage too small');
        require(params.percentageToMigrate <= 100, 'Percentage too large');

        // 1) 把用户的 V2 LP 转入 Pair，再调用 burn 拆出底层两种资产到本合约。
        // 例子：10 LP 可能拆出 2 WBNB + 6000 USDT。
        IUniswapV2Pair(params.pair).transferFrom(msg.sender, params.pair, params.liquidityToMigrate);
        (uint256 amount0V2, uint256 amount1V2) = IUniswapV2Pair(params.pair).burn(address(this));

        // 2) 按比例计算本次用于迁移到 V3 的 token 数量。
        // 例子：若比例 50%，则只迁移一半，另一半后续退款。
        uint256 amount0V2ToMigrate = amount0V2.mul(params.percentageToMigrate) / 100;
        uint256 amount1V2ToMigrate = amount1V2.mul(params.percentageToMigrate) / 100;

        // 3) 授权 NPM 可拉取本次迁移计划使用的 token 上限。
        TransferHelper.safeApprove(params.token0, nonfungiblePositionManager, amount0V2ToMigrate);
        TransferHelper.safeApprove(params.token1, nonfungiblePositionManager, amount1V2ToMigrate);

        // 4) 调 NPM.mint 铸造 V3 仓位 NFT。
        // - amount0Desired/amount1Desired 是愿意投入上限；
        // - amount0Min/amount1Min 是滑点保护；
        // - recipient 指定 NFT 收件人。
        (, , uint256 amount0V3, uint256 amount1V3) =
            INonfungiblePositionManager(nonfungiblePositionManager).mint(
                INonfungiblePositionManager.MintParams({
                    token0: params.token0,
                    token1: params.token1,
                    fee: params.fee,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    amount0Desired: amount0V2ToMigrate,
                    amount1Desired: amount1V2ToMigrate,
                    amount0Min: params.amount0Min,
                    amount1Min: params.amount1Min,
                    recipient: params.recipient,
                    deadline: params.deadline
                })
            );

        // 5) 处理 token0 侧剩余：
        // - 若 NPM 没用满授权，必要时清零授权；
        // - 把剩余资产退回用户；
        // - 若用户要求 `refundAsETH` 且 token0=WETH9，则先解包再退 ETH。
        if (amount0V3 < amount0V2) {
            if (amount0V3 < amount0V2ToMigrate) {
                TransferHelper.safeApprove(params.token0, nonfungiblePositionManager, 0);
            }

            uint256 refund0 = amount0V2 - amount0V3;
            if (params.refundAsETH && params.token0 == WETH9) {
                IWETH9(WETH9).withdraw(refund0);
                TransferHelper.safeTransferETH(msg.sender, refund0);
            } else {
                TransferHelper.safeTransfer(params.token0, msg.sender, refund0);
            }
        }
        // 6) 处理 token1 侧剩余，逻辑同 token0。
        if (amount1V3 < amount1V2) {
            if (amount1V3 < amount1V2ToMigrate) {
                TransferHelper.safeApprove(params.token1, nonfungiblePositionManager, 0);
            }

            uint256 refund1 = amount1V2 - amount1V3;
            if (params.refundAsETH && params.token1 == WETH9) {
                IWETH9(WETH9).withdraw(refund1);
                TransferHelper.safeTransferETH(msg.sender, refund1);
            } else {
                TransferHelper.safeTransfer(params.token1, msg.sender, refund1);
            }
        }
    }
}
