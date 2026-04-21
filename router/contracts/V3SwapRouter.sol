// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@pancakeswap/v3-core/contracts/libraries/SafeCast.sol';
import '@pancakeswap/v3-core/contracts/libraries/TickMath.sol';
import '@pancakeswap/v3-periphery/contracts/libraries/Path.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import './interfaces/IV3SwapRouter.sol';
import './base/PeripheryPaymentsWithFeeExtended.sol';
import './base/OracleSlippage.sol';
import './libraries/Constants.sol';
import './libraries/SmartRouterHelper.sol';

/// @title V3 集中流动性兑换路由
/// @notice 针对 PancakeSwap V3 / UniswapV3 风格 CLAMM：单池有独立 `fee`（如 500/2500/10000），通过 `swap` + 回调 `pancakeV3SwapCallback` 完成代币交割。
/// @dev 继承 `OracleSlippage` 与 `PeripheryImmutableState`（`deployer`、`factory`、`WETH9` 等），`path` 编码遵循 UniswapV3 标准：`token + fee + token + fee + ...`。
/// 使用场景：用户用 USDC 在 0.05% 费池里单跳买 WETH；或 USDC→0.3% 费池→WETH→1% 费池→ARB 多跳，节省总体滑点。
abstract contract V3SwapRouter is IV3SwapRouter, PeripheryPaymentsWithFeeExtended, OracleSlippage, ReentrancyGuard {
    using Path for bytes;
    using SafeCast for uint256;

    /// @dev `amountInCached` 的哨兵值：精确输出路径里用该变量缓存「最后一跳应付 input」；正常记账不可能等于 `uint256.max`，故用作未初始化标记。
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    /// @dev 精确输出多跳时，由池回调写入；`exactOutput` 外部函数读出后与 `amountInMaximum` 比较。
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    /// @notice 回调里携带的上下文：完整 `path` 与「谁出 ERC20」的 `payer`。
    /// @dev 例：`path = abi.encodePacked(USDC, uint24(500), WETH)`，`payer` 为 `msg.sender` 表示由用户钱包在回调里付 USDC 给池子。
    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    /// @notice V3 池在 `swap` 执行过程中调用本回调，要求本合约（路由）向池支付应付的代币。
    /// @dev 使用场景：用户调用 `exactInputSingle` → 池执行 swap → 池算 delta 后回调本函数 → 本函数 `pay` 把 token 从 payer 转给池。
    /// @param amount0Delta 池对 token0 的净需求（>0 表示路由应支付给池的 token0 数量）。
    /// @param amount1Delta 池对 token1 的净需求（同上，对 token1）。
    /// @param _data `abi.encode(SwapCallbackData)`，内含剩余 path 与付款人。
    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        // 若在零流动性区域里两向 delta 均为 0，则无法定义应付金额；此处直接拒绝这类 swap。
        require(amount0Delta > 0 || amount1Delta > 0);
        // 解码出 path 与 payer；例：path 第一段为 USDC|500fee|WETH。
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        // 校验 `msg.sender` 的确是 (tokenIn, tokenOut, fee) 对应池，防止恶意合约冒充池回调骗款。
        SmartRouterHelper.verifyCallback(deployer, tokenIn, tokenOut, fee);

        // 根据哪一侧 delta 为正，判断是 exactInput 还是 exactOutput，以及应付金额 amountToPay。
        // 例：exactInput 且 token0 为输入币时，常见 amount0Delta>0，表示池要从路由收 token0。
        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0
                ? (tokenIn < tokenOut, uint256(amount0Delta))
                : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            // 精确输入：本跳结束时一次性把 tokenIn 付给池（msg.sender 为池地址）。
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else {
            // 精确输出：可能还有后续 hop，需要先递归处理下一池，或已到最后一跳则记录 input 并付款。
            if (data.path.hasMultiplePools()) {
                // 例：path 为 USDC|500|WETH|3000|ARB，当前在第一池回调，则去掉已完成的头段 token，继续 exactOutputInternal 下一池。
                data.path = data.path.skipToken();
                exactOutputInternal(amountToPay, msg.sender, 0, data);
            } else {
                // 最后一跳：把本跳计算得到的应付 input 存到 amountInCached，供外层 `exactOutput` 读取。
                amountInCached = amountToPay;
                // exactOutput 在实现上按「逆向 path」编码，此处语义上应付的 ERC20 为 tokenOut；通过 pay 完成转移。
                pay(tokenOut, data.payer, msg.sender, amountToPay);
            }
        }
    }

    /// @notice 单跳精确内部 swap：`amountIn` 的 tokenIn 换出尽可能多的 tokenOut（受 `sqrtPriceLimitX96` 限制）。
    /// @dev 使用场景：`exactInputSingle` / `exactInput` 的首段或中间段调用；`recipient` 中间跳常为路由自身以暂存输出作为下一跳输入。
    /// @dev 多跳组合或涉及 ETH 时，外层常在 multicall 末尾调用 `refundETH`，避免主币滞留在路由。
    /// @param amountIn 输入数量（已在外部按 CONTRACT_BALANCE 规则解析）。
    /// @param recipient 本跳输出代币接收方；可为魔法地址。
    /// @param sqrtPriceLimitX96 价格限制，0 表示使用 tick 边界默认极值（尽量不换穿某价位）。
    /// @param data 含 path 首段与 payer，供回调使用。
    /// @return amountOut 本跳输出数量（由 pool.swap 返回的 delta 推导）。
    function exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        // 把 0x...01 / 0x...02 解析成 msg.sender / address(this)，便于前端统一传参。
        if (recipient == Constants.MSG_SENDER) recipient = msg.sender;
        else if (recipient == Constants.ADDRESS_THIS) recipient = address(this);

        // 读出本跳 tokenIn、tokenOut、费率；例：USDC、WETH、500。
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();

        // tokenIn 若地址较小则为 zeroForOne（沿价格轴「方向 0→1」swap）。
        bool zeroForOne = tokenIn < tokenOut;

        // 调用核心池 swap：正 amountSpecified 表示 exactInput；回调里完成实际转账。
        (int256 amount0, int256 amount1) =
            SmartRouterHelper.getPool(deployer, tokenIn, tokenOut, fee).swap(
                recipient,
                zeroForOne,
                amountIn.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        // zeroForOne 时输出为 token1，对应 -amount1；反之输出为 token0。返回值转为无符号 amountOut。
        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @notice 单池精确输入：指定 `tokenIn`、`fee`、`tokenOut`，付出 `amountIn`，换得至少 `amountOutMinimum`。
    /// @dev 使用场景：用户在 UI 选择「USDC → WETH，0.05% 池」，填入精确 1000 USDC，设置最小 WETH 产出防夹。
    /// @param params 见 `IV3SwapRouter.ExactInputSingleParams`：`sqrtPriceLimitX96` 一般填 0 表示不限制；非 0 用于高级挂单/区间套利。
    /// @return amountOut 实际换得的 `tokenOut` 数量。
    function exactInputSingle(ExactInputSingleParams memory params)
        external
        payable
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        // `amountIn == 0`：用路由合约当前持有的 tokenIn 全部去换（例如 multicall 先转入再 swap）。
        bool hasAlreadyPaid;
        if (params.amountIn == Constants.CONTRACT_BALANCE) {
            hasAlreadyPaid = true;
            params.amountIn = IERC20(params.tokenIn).balanceOf(address(this));
        }

        amountOut = exactInputInternal(
            params.amountIn,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut),
                payer: hasAlreadyPaid ? address(this) : msg.sender
            })
        );
        // 例：期望至少 0.4 WETH，若池子深度不足只得到 0.39，则 revert 保护用户。
        require(amountOut >= params.amountOutMinimum);
    }

    /// @notice 多跳精确输入：path 编码多段「token|fee|token|fee|...」，第一段付出 `amountIn`，最终到 `recipient`。
    /// @dev 使用场景：USDC 先在 0.05% 池换成 WETH，再经 1% 池换成某小币；比单池深度更深时总滑点更低。
    /// @param params.path 例：`abi.encodePacked(USDC, uint24(500), WETH, uint24(10000), PEPE)`。
    /// @param params.amountIn 第一段输入；0 表示用合约内首 token 全余额。
    /// @return amountOut 最后一币到达 `recipient` 的数量（循环末尾 `params.amountIn` 复用承载「上一跳输出」）。
    function exactInput(ExactInputParams memory params) external payable nonReentrant override returns (uint256 amountOut) {
        bool hasAlreadyPaid;
        if (params.amountIn == Constants.CONTRACT_BALANCE) {
            hasAlreadyPaid = true;
            (address tokenIn, , ) = params.path.decodeFirstPool();
            params.amountIn = IERC20(tokenIn).balanceOf(address(this));
        }

        // 第一跳由用户付；中间跳输出留在路由，payer 切换为 `address(this)`，由路由在回调里代付下一跳输入。
        address payer = hasAlreadyPaid ? address(this) : msg.sender;

        while (true) {
            // 是否还有下一段 path；例：两段池则为 true 一次再 false。
            bool hasMultiplePools = params.path.hasMultiplePools();

            // 中间跳 recipient 为本合约，把输出代币暂存在路由；最后一跳直接发给用户。
            params.amountIn = exactInputInternal(
                params.amountIn,
                hasMultiplePools ? address(this) : params.recipient,
                0,
                SwapCallbackData({
                    path: params.path.getFirstPool(),
                    payer: payer
                })
            );

            if (hasMultiplePools) {
                // 下一跳由路由持有代币并作为付款人（回调里 payer=address(this)）。
                payer = address(this);
                params.path = params.path.skipToken();
            } else {
                // 循环结束时，`params.amountIn` 已是最后一段的 output 数量。
                amountOut = params.amountIn;
                break;
            }
        }

        require(amountOut >= params.amountOutMinimum);
    }

    /// @notice 单跳精确输出内部实现：池应给 recipient 恰好 `amountOut`（本跳语义），路由在回调中支付 input。
    /// @dev 使用场景：`exactOutputSingle` 调用；path 在 exactOutput 系列里按「逆向」打包：`tokenOut|fee|tokenIn`。
    /// @return amountIn 本跳池从路由收取的输入代币数量（由 swap 返回 delta 换算）。
    function exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        if (recipient == Constants.MSG_SENDER) recipient = msg.sender;
        else if (recipient == Constants.ADDRESS_THIS) recipient = address(this);

        // 注意：exactOutput 的 path 第一字段是 tokenOut（用户要拿到的），第二段 fee，第三段才是 tokenIn（用户要付的）。
        (address tokenOut, address tokenIn, uint24 fee) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        // amountSpecified 为负表示 exactOutput：告诉池「我要固定数量的 output」。
        (int256 amount0Delta, int256 amount1Delta) =
            SmartRouterHelper.getPool(deployer, tokenIn, tokenOut, fee).swap(
                recipient,
                zeroForOne,
                -amountOut.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));
        // 未设价格限制时，要求池实际交付的 output 必须等于请求的 amountOut，否则可能存在部分成交边界情况。
        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
    }

    /// @notice 单池精确输出：希望拿到恰好 `amountOut` 的 `tokenOut`，最多愿意付 `amountInMaximum` 的 `tokenIn`。
    /// @dev 使用场景：用户要精确 2 WETH，用于后续合约拆单；接受最多花 7000 USDC，若池价太贵超过上限则失败。
    /// @return amountIn 实际消耗的 `tokenIn`。
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        nonReentrant
        returns (uint256 amountIn)
    {
        amountIn = exactOutputInternal(
            params.amountOut,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn), payer: msg.sender})
        );

        require(amountIn <= params.amountInMaximum);
        // 单跳也重置缓存，避免脏数据影响后续交易（虽然单跳不读 amountInCached）。
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    /// @notice 多跳精确输出：`params.path` 为逆向编码的多段路径，目标为最终精确产出 `amountOut`。
    /// @dev 使用场景：用户要精确收到某数量的末端代币，由池回调链式触发多段 `exactOutputInternal`；具体路径示例见前端 path 构造文档。
    /// @return amountIn 读取回调阶段写入的 `amountInCached`，并与 `amountInMaximum` 比较做上限保护（与最后一跳记账相关，调用方按产品约定解读）。
    function exactOutput(ExactOutputParams calldata params) external payable override nonReentrant returns (uint256 amountIn) {
        exactOutputInternal(
            params.amountOut,
            params.recipient,
            0,
            SwapCallbackData({path: params.path, payer: msg.sender})
        );

        amountIn = amountInCached;
        require(amountIn <= params.amountInMaximum);
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }
}
