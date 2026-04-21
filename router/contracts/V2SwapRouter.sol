// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@pancakeswap/v3-core/contracts/libraries/LowGasSafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import './interfaces/IV2SwapRouter.sol';
import './base/ImmutableState.sol';
import './base/PeripheryPaymentsWithFeeExtended.sol';
import './libraries/Constants.sol';
import './libraries/SmartRouterHelper.sol';

/// @title V2 兑换路由（无状态执行）
/// @notice 针对 PancakeSwap V2 风格 AMM（x*y=k）在链上顺序 hop 兑换；本合约为 `abstract`，由 `SmartRouter` 等最终合约继承部署。
/// @dev 状态变量来自父合约：
/// - `factoryV2`：创建 Pair 的工厂，用于 `pairFor`。
/// - `positionManager`：NFT 头寸管理器（本文件逻辑主要用 factory + pair）。
/// 使用场景：用户持有 CAKE，想在 V2 池里换成 BUSD，路径为 `[CAKE, WBNB, BUSD]`，调用 `swapExactTokensForTokens` 指定精确输入与最小输出防夹。
abstract contract V2SwapRouter is IV2SwapRouter, ImmutableState, PeripheryPaymentsWithFeeExtended, ReentrancyGuard {
    using LowGasSafeMath for uint256;

    /// @notice 在已收到输入代币的前提下，沿 `path` 逐跳调用 Pair.swap，把输出送给下一跳 Pair 或最终 `_to`。
    /// @dev 支持「转账抽税」类代币：输入量用「Pair 内实际余额 − 储备」推算，而不是盲目信任调用方传入数值。
    /// @dev 多跳组合交易时，应在所有 swap 最后调用 `refundETH`（由外层 multicall/路由约定），避免 ETH 滞留在路由合约。
    /// @param path 代币地址序列，例：`[USDT, WBNB, CAKE]` 表示先 USDT→WBNB 再 WBNB→CAKE。
    /// @param _to 最后一跳输出接收方；中间跳会自动改为「下一跳的 Pair 地址」以便资金串联。
    function _swap(address[] memory path, address _to) private {
        // 例：path 长度为 3，则循环 2 次：先在 USDT-WBNB 池换，再在 WBNB-CAKE 池换。
        for (uint256 i; i < path.length - 1; i++) {
            // 当前这一步的输入币与输出币，例如 i=0 时 input=USDT, output=WBNB。
            (address input, address output) = (path[i], path[i + 1]);
            // token0 为排序后较小地址，供 UniswapV2Pair 约定 amount0Out/amount1Out 方向。
            (address token0, ) = SmartRouterHelper.sortTokens(input, output);
            // 用工厂 + 两币地址计算确定性 Pair 地址（CREATE2），无需链上查询工厂。
            IUniswapV2Pair pair = IUniswapV2Pair(SmartRouterHelper.pairFor(factoryV2, input, output));
            uint256 amountInput;
            uint256 amountOutput;
            // 用大括号限制局部变量作用域，避免「stack too deep」编译错误。
            {
                // 读出池子当前储备；若有人事先 donate 代币进 Pair，余额会大于 reserve，差额视为真实输入。
                (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
                // 把储备按 token0/token1 对齐到「当前 input 一侧」与「output 一侧」。
                (uint256 reserveInput, uint256 reserveOutput) =
                    input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                // 实际进入本 hop 的 input 数量 = Pair 合约 ERC20 余额减去记账储备（兼容 fee-on-transfer）。
                amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
                // 按恒定乘积公式计算本跳应给出的 output（含 0.3% 等池子手续费逻辑，具体在 Helper 内）。
                amountOutput = SmartRouterHelper.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            // UniswapV2Pair.swap 要求指定从 token0 还是 token1 转出；这里把 amountOutput 填到正确一侧。
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            // 若不是最后一跳，输出直接打到「下一跳 path[i+2] 的 Pair」，实现原子串联；最后一跳打到用户指定的 `_to`。
            address to = i < path.length - 2 ? SmartRouterHelper.pairFor(factoryV2, output, path[i + 2]) : _to;
            // 触发链上 swap；data 为空表示非闪电贷回调路径。
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /// @notice 精确输入：付出固定数量的 `path[0]`，换取尽可能多的最后一币，且实际到手 ≥ `amountOutMin`。
    /// @dev 使用场景：钱包里有 100 USDT，想全部换成 BUSD，能接受滑点，调用本函数并设 `amountOutMin=99.5e18` 防止被抢跑吃亏。
    /// @dev 若 `amountIn == Constants.CONTRACT_BALANCE`（即 0），表示「用本路由合约当前持有的 `path[0]` 全部余额」去换，典型例子：上一笔 multicall 先把代币转进路由，再 0 输入触发 swap。
    /// @param amountIn 输入代币数量；传 0 表示用合约自身余额全量（见上）。
    /// @param amountOutMin 用户愿意接受的最后一币最小值，不满足则 `revert`。
    /// @param path 兑换路径，首元素为输入代币，尾元素为输出代币。
    /// @param to 最终收款地址；可传 `Constants.MSG_SENDER`(address(1)) 表示发给 `msg.sender`，或 `ADDRESS_THIS` 表示留在路由。
    /// @return amountOut 最后一币实际增量（通过 to 地址余额差计算，兼容转账税代币）。
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external payable override nonReentrant returns (uint256 amountOut) {
        IERC20 srcToken = IERC20(path[0]);
        IERC20 dstToken = IERC20(path[path.length - 1]);

        // `amountIn == 0`（CONTRACT_BALANCE）：例如聚合器先 `transfer` USDT 到路由，再调用 swap，用合约账面全部 USDT 去换。
        bool hasAlreadyPaid;
        if (amountIn == Constants.CONTRACT_BALANCE) {
            hasAlreadyPaid = true;
            amountIn = srcToken.balanceOf(address(this));
        }

        // 正常情况：从用户 `msg.sender` 把代币付到「第一跳的 Pair」；若已预付则从路由地址付到 Pair（避免二次从用户扣款）。
        pay(
            address(srcToken),
            hasAlreadyPaid ? address(this) : msg.sender,
            SmartRouterHelper.pairFor(factoryV2, address(srcToken), path[1]),
            amountIn
        );

        // 把魔法地址解析成真实 EOA/合约地址，节省 calldata gas（前端常传 0x00...01）。
        if (to == Constants.MSG_SENDER) to = msg.sender;
        else if (to == Constants.ADDRESS_THIS) to = address(this);

        // 记录兑换前接收方 dst 余额，用于后面做差得到真实 output（兼容 dst 为收税代币）。
        uint256 balanceBefore = dstToken.balanceOf(to);

        // 执行整条 path 的 hop swap，最终代币直接进 `to`。
        _swap(path, to);

        // 实际输出 = 兑换后余额 − 兑换前余额。
        amountOut = dstToken.balanceOf(to).sub(balanceBefore);
        // 例：期望至少 99 BUSD，若池子太浅只得到 98.9，则此处失败保护用户。
        require(amountOut >= amountOutMin);
    }

    /// @notice 精确输出：希望得到恰好 `amountOut` 的最后一币，愿意最多支付 `amountInMax` 的 `path[0]`。
    /// @dev 使用场景：用户要「刚好还 1000 DAI 借款」，多一分都不想多付，可先链下模拟 `getAmountsIn` 再设 `amountInMax` 留一点余量。
    /// @param amountOut 目标输出数量（最后一币精确到账）。
    /// @param amountInMax 输入代币可接受上限；链上先算所需 input，超过则 `revert`。
    /// @param path 与 V2 `getAmountsIn` 约定一致的有序路径。
    /// @param to 输出收款地址，魔法地址规则同上。
    /// @return amountIn 实际消耗的 `path[0]` 数量（由 `getAmountsIn` 第一个元素给出）。
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external payable override nonReentrant returns (uint256 amountIn) {
        address srcToken = path[0];

        // 例：要精确 1 WBNB out，反推需要从 USDT 付多少 in；若反推结果 > amountInMax 则整体回滚。
        amountIn = SmartRouterHelper.getAmountsIn(factoryV2, amountOut, path)[0];
        require(amountIn <= amountInMax);

        // 从用户拉取恰好 amountIn 到第一跳 Pair（V2 标准：先 transfer 再 swap）。
        pay(srcToken, msg.sender, SmartRouterHelper.pairFor(factoryV2, srcToken, path[1]), amountIn);

        if (to == Constants.MSG_SENDER) to = msg.sender;
        else if (to == Constants.ADDRESS_THIS) to = address(this);

        _swap(path, to);
    }
}
