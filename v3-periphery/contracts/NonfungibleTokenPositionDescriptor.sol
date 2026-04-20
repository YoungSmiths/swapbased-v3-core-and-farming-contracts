// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol';
import '@uniswap/lib/contracts/libraries/SafeERC20Namer.sol';

import './libraries/ChainId.sol';
import './interfaces/INonfungiblePositionManager.sol';
import './interfaces/INonfungibleTokenPositionDescriptor.sol';
import './interfaces/IERC20Metadata.sol';
import './libraries/PoolAddress.sol';
import './libraries/NFTDescriptor.sol';
import './libraries/TokenRatioSortOrder.sol';
import './NFTDescriptorEx.sol';

/// @title NonfungibleTokenPositionDescriptor
/// @notice 链上版 LP NFT 描述器：读取仓位与池子数据，生成完整 tokenURI（JSON + SVG）。
/// @dev 使用场景：钱包或 NFT 市场调用 `tokenURI` 展示 V3 LP NFT 的名称、描述、图片。
contract NonfungibleTokenPositionDescriptor is INonfungibleTokenPositionDescriptor {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /// @notice WETH9 地址，用于把其符号替换为原生币标签（例如 ETH/BNB）。
    address public immutable WETH9;
    /// @notice 原生币标签（bytes32，0 结尾）。
    /// @dev 例子：可存 "ETH" 或 "BNB"，用于前端友好的符号展示。
    bytes32 public immutable nativeCurrencyLabelBytes;

    /// @notice 实际 JSON/SVG 构建器地址（NFTDescriptorEx）。
    /// @dev 本合约负责“采集参数”，具体字符串拼装委托给该合约。
    address public immutable nftDescriptorEx;

    /// @notice 构造函数：注入 WETH9、原生币标签、以及扩展描述器地址。
    /// @param _WETH9 WETH9 合约地址。
    /// @param _nativeCurrencyLabelBytes 原生币标签（bytes32）。
    /// @param _nftDescriptorEx NFTDescriptorEx 地址。
    constructor(address _WETH9, bytes32 _nativeCurrencyLabelBytes, address _nftDescriptorEx) {
        WETH9 = _WETH9;
        nativeCurrencyLabelBytes = _nativeCurrencyLabelBytes;
        nftDescriptorEx = _nftDescriptorEx;
    }

    /// @notice 把 bytes32 的原生币标签转成字符串。
    /// @return 原生币文本（如 "ETH" / "BNB"）。
    /// @dev 核心逻辑：从左到右找到第一个 0 字节作为字符串结束位置，再复制有效部分。
    function nativeCurrencyLabel() public view returns (string memory) {
        uint256 len = 0;
        while (len < 32 && nativeCurrencyLabelBytes[len] != 0) {
            len++;
        }
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = nativeCurrencyLabelBytes[i];
        }
        return string(b);
    }

    /// @inheritdoc INonfungibleTokenPositionDescriptor
    /// @notice 生成 LP NFT 的 tokenURI。
    /// @param positionManager NonfungiblePositionManager 合约实例。
    /// @param tokenId LP NFT 编号。
    /// @return 完整 tokenURI（通常为 data URI 或 HTTP 包装后的 data URI）。
    /// @dev 使用场景：钱包查询 NFT 元数据时调用。
    /// @dev 核心逻辑（逐行理解）：
    /// 1) 读取仓位基础信息（token0/token1/fee/tick 区间）；
    /// 2) 用 deployer + PoolKey 计算池地址并读取当前 tick；
    /// 3) 决定展示比价方向（flipRatio）；
    /// 4) 组装参数交给 `NFTDescriptorEx.constructTokenURI` 输出最终 metadata。
    /// @dev 例子：用户持有 USDT/WBNB 0.25% 仓位，tokenURI 会带上该池当前 tick 和用户区间边界。
    function tokenURI(INonfungiblePositionManager positionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        (, , address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, , , , , ) =
            positionManager.positions(tokenId);

        // 通过 deployer + token0/token1/fee 计算池地址（与 Factory createPool 规则一致）。
        IPancakeV3Pool pool =
            IPancakeV3Pool(
                PoolAddress.computeAddress(
                    positionManager.deployer(),
                    PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})
                )
            );

        // 根据链和代币优先级决定是否翻转展示方向（影响名称中的价格上下界文本）。
        bool _flipRatio = flipRatio(token0, token1, ChainId.get());
        address quoteTokenAddress = !_flipRatio ? token1 : token0;
        address baseTokenAddress = !_flipRatio ? token0 : token1;
        // 当前市场价格 tick（用于判断仓位是否 in range 并用于绘图）。
        (, int24 tick, , , , , ) = pool.slot0();

        return
            NFTDescriptorEx(nftDescriptorEx).constructTokenURI(
                NFTDescriptorEx.ConstructTokenURIParams({
                    tokenId: tokenId,
                    quoteTokenAddress: quoteTokenAddress,
                    baseTokenAddress: baseTokenAddress,
                    quoteTokenSymbol: quoteTokenAddress == WETH9
                        ? nativeCurrencyLabel()
                        : SafeERC20Namer.tokenSymbol(quoteTokenAddress),
                    baseTokenSymbol: baseTokenAddress == WETH9
                        ? nativeCurrencyLabel()
                        : SafeERC20Namer.tokenSymbol(baseTokenAddress),
                    quoteTokenDecimals: IERC20Metadata(quoteTokenAddress).decimals(),
                    baseTokenDecimals: IERC20Metadata(baseTokenAddress).decimals(),
                    flipRatio: _flipRatio,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    tickCurrent: tick,
                    tickSpacing: pool.tickSpacing(),
                    fee: fee,
                    poolAddress: address(pool)
                })
            );
    }

    /// @notice 判断是否需要翻转展示比价方向。
    /// @param token0 池代币0。
    /// @param token1 池代币1。
    /// @param chainId 当前链 ID。
    /// @return true 表示应翻转（token0/token1 的优先级关系触发）。
    /// @dev 使用场景：让用户看到更习惯的价格表达，例如稳定币作分子更直观。
    function flipRatio(
        address token0,
        address token1,
        uint256 chainId
    ) public view returns (bool) {
        return tokenRatioPriority(token0, chainId) > tokenRatioPriority(token1, chainId);
    }

    /// @notice 返回 token 在展示排序中的优先级分值。
    /// @param token 代币地址。
    /// @param chainId 链 ID。
    /// @return 优先级分值（越大优先级越高）。
    /// @dev 例子（主网）：USDC/USDT/DAI 倾向作为“价格分子”展示，WBTC 倾向作为“分母”。
    function tokenRatioPriority(address token, uint256 chainId) public view returns (int256) {
        if (token == WETH9) {
            return TokenRatioSortOrder.DENOMINATOR;
        }
        if (chainId == 1) {
            if (token == USDC) {
                return TokenRatioSortOrder.NUMERATOR_MOST;
            } else if (token == USDT) {
                return TokenRatioSortOrder.NUMERATOR_MORE;
            } else if (token == DAI) {
                return TokenRatioSortOrder.NUMERATOR;
            } else if (token == TBTC) {
                return TokenRatioSortOrder.DENOMINATOR_MORE;
            } else if (token == WBTC) {
                return TokenRatioSortOrder.DENOMINATOR_MOST;
            } else {
                return 0;
            }
        }
        return 0;
    }
}
