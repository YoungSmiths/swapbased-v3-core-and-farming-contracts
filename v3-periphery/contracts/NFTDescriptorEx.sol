// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.0;
pragma abicoder v2;

import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol';
import '@pancakeswap/v3-core/contracts/libraries/TickMath.sol';
import '@pancakeswap/v3-core/contracts/libraries/BitMath.sol';
import '@pancakeswap/v3-core/contracts/libraries/FullMath.sol';
import '@openzeppelin/contracts/utils/Strings.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/math/SignedSafeMath.sol';
import 'base64-sol/base64.sol';
import './libraries/HexStrings.sol';
import './libraries/NFTSVG.sol';

/// @title NFTDescriptorEx
/// @notice V3 LP NFT 元数据与 SVG 生成器：把仓位参数编码成可展示的 JSON + SVG。
/// @dev 使用场景：`NonfungibleTokenPositionDescriptor.tokenURI()` 会调用本合约，返回前端钱包可直接渲染的 metadata。
/// 例子：用户持有 USDT/WBNB 的 LP NFT，钱包里看到的“价格区间、费率、配色背景图”都由这里组装。
contract NFTDescriptorEx {
    using TickMath for int24;
    using Strings for uint256;
    using SafeMath for uint256;
    using SafeMath for uint160;
    using SafeMath for uint8;
    using SignedSafeMath for int256;
    using HexStrings for uint256;

    /// @notice `sqrt(10) * 2^128` 的常量，用于奇数位小数精度换算。
    /// @dev 例子：当 token 精度差是 1、3、5 这种奇数时，需要乘/除 sqrt(10) 做中间矫正。
    uint256 constant sqrt10X128 = 1076067327063303206878105757264492625226;

    /// @notice 组装 tokenURI 所需的全部输入参数。
    /// @dev 这些参数通常由 `NonfungibleTokenPositionDescriptor` 从 PositionManager + Pool 实时读取后传入。
    struct ConstructTokenURIParams {
        uint256 tokenId;
        address quoteTokenAddress;
        address baseTokenAddress;
        string quoteTokenSymbol;
        string baseTokenSymbol;
        uint8 quoteTokenDecimals;
        uint8 baseTokenDecimals;
        bool flipRatio;
        int24 tickLower;
        int24 tickUpper;
        int24 tickCurrent;
        int24 tickSpacing;
        uint24 fee;
        address poolAddress;
    }

    /// @notice 管理员地址，可切换返回模式（纯 data URI / HTTP 包装链接）。
    address public owner;

    /// @notice true: 返回 `NFTDomain/dataURI`；false: 直接返回 data URI。
    /// @dev 使用场景：某些前端希望走统一网关域名缓存，可开启 true。
    bool private switchToHttpLink;

    /// @notice 当 `switchToHttpLink=true` 时使用的域名前缀。
    /// @dev 例子：可配置为 `https://nft-meta.swapbased.xyz`。
    string private NFTDomain;

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event ToggleSwitchAndUpdateNFTDomain(address indexed sender, bool switchToHttpLink, string NFTDomain);

    /// @notice 仅管理员可调用。
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /// @notice 构造函数：初始化管理员并默认启用 HTTP 包装模式。
    /// @dev 初始 `switchToHttpLink=true`，若 `NFTDomain` 未配置会导致返回 `"/data:..."` 形式，可后续由 owner 设置域名。
    constructor() {
        owner = msg.sender;
        switchToHttpLink = true;
    }

    /// @notice 构建完整 tokenURI（JSON+SVG），可选再包一层 HTTP 前缀。
    /// @param params LP NFT 展示所需参数（代币、费率、tick、池地址等）。
    /// @return 最终 tokenURI 字符串。
    /// @dev 使用场景：钱包/市场拉取 NFT metadata 时调用。
    /// @dev 实际例子：用户查看 tokenId=1024 的 LP NFT，
    /// 本函数会生成名字如 `Pancake - 0.25% - USDT/WBNB - ...`，并嵌入对应 SVG 图像。
    function constructTokenURI(ConstructTokenURIParams memory params) public view returns (string memory) {
        // 1) 生成 NFT 名称：包含费率、交易对、价格区间。
        string memory name = generateName(params, feeToPercentString(params.fee));
        // 2) 生成描述前半段：池子说明 + 池地址。
        string memory descriptionPartOne =
        generateDescriptionPartOne(
            escapeQuotes(params.quoteTokenSymbol),
            escapeQuotes(params.baseTokenSymbol),
            addressToString(params.poolAddress)
        );
        // 3) 生成描述后半段：token 地址、费率、tokenId 与风险提示。
        string memory descriptionPartTwo =
        generateDescriptionPartTwo(
            params.tokenId.toString(),
            escapeQuotes(params.baseTokenSymbol),
            addressToString(params.quoteTokenAddress),
            addressToString(params.baseTokenAddress),
            feeToPercentString(params.fee)
        );
        // 4) 生成 SVG 并转 Base64（用于 image 字段）。
        string memory image = Base64.encode(bytes(generateSVGImage(params)));

        // 5) 组装 JSON，再整体转 Base64，输出标准 data:application/json;base64,... URI。
        string memory tokenUri = string(
            abi.encodePacked(
                'data:application/json;base64,',
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"',
                            name,
                            '", "description":"',
                            descriptionPartOne,
                            descriptionPartTwo,
                            '", "image": "',
                            'data:image/svg+xml;base64,',
                            image,
                            '"}'
                        )
                    )
                )
            )
        );

        // 6) 根据开关决定返回模式：
        // - true: 返回 `NFTDomain + "/" + tokenUri`（便于走网关代理）；
        // - false: 直接返回原始 data URI（最标准、最去中心化）。
        return switchToHttpLink ? string(abi.encodePacked(
                bytes(NFTDomain),
                '/',
                bytes(tokenUri)
            )) : tokenUri;
    }

    /// @notice 转义 symbol 中的双引号，防止拼接 JSON 时格式破坏。
    /// @param symbol 原始代币符号。
    /// @return 转义后的安全字符串。
    /// @dev 例子：`ABC"DEF` 会转成 `ABC\"DEF`。
    function escapeQuotes(string memory symbol) internal pure returns (string memory) {
        bytes memory symbolBytes = bytes(symbol);
        uint8 quotesCount = 0;
        for (uint8 i = 0; i < symbolBytes.length; i++) {
            if (symbolBytes[i] == '"') {
                quotesCount++;
            }
        }
        if (quotesCount > 0) {
            bytes memory escapedBytes = new bytes(symbolBytes.length + (quotesCount));
            uint256 index;
            for (uint8 i = 0; i < symbolBytes.length; i++) {
                if (symbolBytes[i] == '"') {
                    escapedBytes[index++] = '\\';
                }
                escapedBytes[index++] = symbolBytes[i];
            }
            return string(escapedBytes);
        }
        return symbol;
    }

    /// @notice 生成 metadata 描述前半段。
    /// @dev 使用场景：向钱包解释“这是哪个池子的 LP 头寸 NFT”。
    function generateDescriptionPartOne(
        string memory quoteTokenSymbol,
        string memory baseTokenSymbol,
        string memory poolAddress
    ) private pure returns (string memory) {
        return
        string(
            abi.encodePacked(
                'This NFT represents a liquidity position in a Pancake V3 ',
                quoteTokenSymbol,
                '-',
                baseTokenSymbol,
                ' pool. ',
                'The owner of this NFT can modify or redeem the position.\\n',
                '\\nPool Address: ',
                poolAddress,
                '\\n',
                quoteTokenSymbol
            )
        );
    }

    /// @notice 生成 metadata 描述后半段。
    /// @dev 使用场景：补充 token 地址、费率、tokenId 以及仿冒风险提示。
    function generateDescriptionPartTwo(
        string memory tokenId,
        string memory baseTokenSymbol,
        string memory quoteTokenAddress,
        string memory baseTokenAddress,
        string memory feeTier
    ) private pure returns (string memory) {
        return
        string(
        abi.encodePacked(
        ' Address: ',
        quoteTokenAddress,
        '\\n',
        baseTokenSymbol,
        ' Address: ',
        baseTokenAddress,
        '\\nFee Tier: ',
        feeTier,
        '\\nToken ID: ',
        tokenId,
        '\\n\\n',
        unicode'⚠️ DISCLAIMER: Due diligence is imperative when assessing this NFT. Make sure token addresses match the expected tokens, as token symbols may be imitated.'
        )
    );
    }

    /// @notice 生成 NFT 展示名称（name 字段）。
    /// @dev 名称由“协议名 + 费率 + 交易对 + 下界<>上界价格”组成，便于用户一眼识别仓位范围。
    function generateName(ConstructTokenURIParams memory params, string memory feeTier)
    private
    pure
    returns (string memory)
    {
    return
        string(
            abi.encodePacked(
                'Pancake - ',
                feeTier,
                ' - ',
                escapeQuotes(params.quoteTokenSymbol),
                '/',
                escapeQuotes(params.baseTokenSymbol),
                ' - ',
                tickToDecimalString(
                    !params.flipRatio ? params.tickLower : params.tickUpper,
                    params.tickSpacing,
                    params.baseTokenDecimals,
                    params.quoteTokenDecimals,
                    params.flipRatio
                ),
                '<>',
                tickToDecimalString(
                    !params.flipRatio ? params.tickUpper : params.tickLower,
                    params.tickSpacing,
                    params.baseTokenDecimals,
                    params.quoteTokenDecimals,
                    params.flipRatio
                )
            )
        );
    }

    /// @notice 小数文本拼接的中间参数结构。
    /// @dev 用于统一生成“价格字符串/百分比字符串”，避免重复拼接逻辑。
    struct DecimalStringParams {
        // significant figures of decimal
        uint256 sigfigs;
        // length of decimal string
        uint8 bufferLength;
        // ending index for significant figures (funtion works backwards when copying sigfigs)
        uint8 sigfigIndex;
        // index of decimal place (0 if no decimal)
        uint8 decimalIndex;
        // start index for trailing/leading 0's for very small/large numbers
        uint8 zerosStartIndex;
        // end index for trailing/leading 0's for very small/large numbers
        uint8 zerosEndIndex;
        // true if decimal number is less than one
        bool isLessThanOne;
        // true if string should include "%"
        bool isPercent;
    }

    /// @notice 按 `DecimalStringParams` 生成最终数字字符串。
    /// @param params 预计算后的字符串布局参数。
    /// @return 格式化后的字符串。
    /// @dev 核心逻辑（逐行理解）：
    /// 1) 先创建固定长度 buffer；
    /// 2) 按需写入 `%`、`0.` 前缀；
    /// 3) 补前导/尾随 0；
    /// 4) 从低位到高位倒序填充有效数字，并在指定位置插入小数点。
    /// 例子：可输出 `0.0025%`、`123.45`、`0.000012` 等不同形态。
    function generateDecimalString(DecimalStringParams memory params) private pure returns (string memory) {
        bytes memory buffer = new bytes(params.bufferLength);
        // 末尾追加百分号（仅费率展示会开启）。
        if (params.isPercent) {
            buffer[buffer.length - 1] = '%';
        }
        // 小于 1 的数字统一加 "0." 前缀，避免显示成 ".25" 这种不友好格式。
        if (params.isLessThanOne) {
            buffer[0] = '0';
            buffer[1] = '.';
        }

        // 填充预留的 0 区间（可能是前导 0，也可能是尾随 0）。
        for (uint256 zerosCursor = params.zerosStartIndex; zerosCursor < params.zerosEndIndex.add(1); zerosCursor++) {
            buffer[zerosCursor] = bytes1(uint8(48));
        }
        // 倒序写入有效数字，并在指定位置插入小数点。
        while (params.sigfigs > 0) {
            if (params.decimalIndex > 0 && params.sigfigIndex == params.decimalIndex) {
                buffer[params.sigfigIndex--] = '.';
            }
            buffer[params.sigfigIndex--] = bytes1(uint8(uint256(48).add(params.sigfigs % 10)));
            params.sigfigs /= 10;
        }
        return string(buffer);
    }

    /// @notice 将 tick 对应价格转成人类可读十进制字符串。
    /// @param tick 目标 tick。
    /// @param tickSpacing 池子 tick 间距。
    /// @param baseTokenDecimals baseToken 精度。
    /// @param quoteTokenDecimals quoteToken 精度。
    /// @param flipRatio 是否翻转价格展示方向。
    /// @return 十进制价格文本或 `MIN/MAX`。
    /// @dev 使用场景：生成 NFT 名称中的价格边界。
    /// 例子：区间下界 tick 对应价格可能显示 `2800.12`；极值边界则显示 `MIN` 或 `MAX`。
    function tickToDecimalString(
        int24 tick,
        int24 tickSpacing,
        uint8 baseTokenDecimals,
        uint8 quoteTokenDecimals,
        bool flipRatio
    ) internal pure returns (string memory) {
        if (tick == (TickMath.MIN_TICK / tickSpacing) * tickSpacing) {
            return !flipRatio ? 'MIN' : 'MAX';
        } else if (tick == (TickMath.MAX_TICK / tickSpacing) * tickSpacing) {
            return !flipRatio ? 'MAX' : 'MIN';
        } else {
            uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
            if (flipRatio) {
                sqrtRatioX96 = uint160(uint256(1 << 192).div(sqrtRatioX96));
            }
            return fixedPointToDecimalString(sqrtRatioX96, baseTokenDecimals, quoteTokenDecimals);
        }
    }

    /// @notice 对大整数保留 5 位有效数字并进行四舍五入。
    /// @param value 原始值（通常多保留 1 位用于舍入判断）。
    /// @param digits 总位数。
    /// @return 舍入后的 5 位有效数字；是否产生进位导致额外位数。
    /// @dev 例子：99999 舍入后进位为 100000，需要标记 `extraDigit=true`。
    function sigfigsRounded(uint256 value, uint8 digits) private pure returns (uint256, bool) {
        bool extraDigit;
        if (digits > 5) {
            value = value.div((10**(digits - 5)));
        }
        bool roundUp = value % 10 > 4;
        value = value.div(10);
        if (roundUp) {
            value = value + 1;
        }
        // 99999 -> 100000 gives an extra sigfig
        if (value == 100000) {
            value /= 10;
            extraDigit = true;
        }
        return (value, extraDigit);
    }

    /// @notice 按 token 精度差修正 `sqrtRatioX96`，让价格展示更符合人类习惯。
    /// @dev 例子：USDT(6) / WBNB(18) 有 12 位精度差，若不修正会导致展示价格量纲错误。
    function adjustForDecimalPrecision(
        uint160 sqrtRatioX96,
        uint8 baseTokenDecimals,
        uint8 quoteTokenDecimals
    ) private pure returns (uint256 adjustedSqrtRatioX96) {
        uint256 difference = abs(int256(baseTokenDecimals).sub(int256(quoteTokenDecimals)));
        if (difference > 0 && difference <= 18) {
            if (baseTokenDecimals > quoteTokenDecimals) {
                adjustedSqrtRatioX96 = sqrtRatioX96.mul(10**(difference.div(2)));
                if (difference % 2 == 1) {
                    adjustedSqrtRatioX96 = FullMath.mulDiv(adjustedSqrtRatioX96, sqrt10X128, 1 << 128);
                }
            } else {
                adjustedSqrtRatioX96 = sqrtRatioX96.div(10**(difference.div(2)));
                if (difference % 2 == 1) {
                    adjustedSqrtRatioX96 = FullMath.mulDiv(adjustedSqrtRatioX96, 1 << 128, sqrt10X128);
                }
            }
        } else {
            adjustedSqrtRatioX96 = uint256(sqrtRatioX96);
        }
    }

    /// @notice 返回绝对值（int256 -> uint256）。
    function abs(int256 x) private pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @notice 将定点 sqrt 价格转成十进制价格字符串（保留核心有效数字）。
    /// @param sqrtRatioX96 sqrt(price) 的 Q64.96 值。
    /// @param baseTokenDecimals baseToken 精度。
    /// @param quoteTokenDecimals quoteToken 精度。
    /// @return 可读价格字符串。
    /// @dev 核心逻辑（逐行理解）：
    /// 1) 先做 token 精度修正；
    /// 2) 再平方得到 price，并按大小分支决定放大倍率；
    /// 3) 统计位数 + 四舍五入；
    /// 4) 组织 `DecimalStringParams`，交给 `generateDecimalString` 输出最终文本。
    /// @dev 例子：可把链上定点值转换为 `0.00052` 或 `1823.7` 这种用户能直接理解的价格。
    function fixedPointToDecimalString(
        uint160 sqrtRatioX96,
        uint8 baseTokenDecimals,
        uint8 quoteTokenDecimals
    ) internal pure returns (string memory) {
        uint256 adjustedSqrtRatioX96 = adjustForDecimalPrecision(sqrtRatioX96, baseTokenDecimals, quoteTokenDecimals);
        uint256 value = FullMath.mulDiv(adjustedSqrtRatioX96, adjustedSqrtRatioX96, 1 << 64);

        bool priceBelow1 = adjustedSqrtRatioX96 < 2**96;
        if (priceBelow1) {
            // 10 ** 43 is precision needed to retreive 5 sigfigs of smallest possible price + 1 for rounding
            value = FullMath.mulDiv(value, 10**44, 1 << 128);
        } else {
            // leave precision for 4 decimal places + 1 place for rounding
            value = FullMath.mulDiv(value, 10**5, 1 << 128);
        }

        // get digit count
        uint256 temp = value;
        uint8 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        // don't count extra digit kept for rounding
        digits = digits - 1;

        // address rounding
        (uint256 sigfigs, bool extraDigit) = sigfigsRounded(value, digits);
        if (extraDigit) {
            digits++;
        }

        DecimalStringParams memory params;
        if (priceBelow1) {
            // 7 bytes ( "0." and 5 sigfigs) + leading 0's bytes
            params.bufferLength = uint8(uint8(7).add(uint8(43).sub(digits)));
            params.zerosStartIndex = 2;
            params.zerosEndIndex = uint8(uint256(43).sub(digits).add(1));
            params.sigfigIndex = uint8(params.bufferLength.sub(1));
        } else if (digits >= 9) {
            // no decimal in price string
            params.bufferLength = uint8(digits.sub(4));
            params.zerosStartIndex = 5;
            params.zerosEndIndex = uint8(params.bufferLength.sub(1));
            params.sigfigIndex = 4;
        } else {
            // 5 sigfigs surround decimal
            params.bufferLength = 6;
            params.sigfigIndex = 5;
            params.decimalIndex = uint8(digits.sub(5).add(1));
        }
        params.sigfigs = sigfigs;
        params.isLessThanOne = priceBelow1;
        params.isPercent = false;

        return generateDecimalString(params);
    }

    /// @notice 把 fee（1e6 分母）格式化成百分比字符串。
    /// @param fee 费率数值（如 500、2500、10000）。
    /// @return 百分比文本（如 `0.05%`、`0.25%`、`1%`）。
    /// @dev 使用场景：用于 NFT 名称和描述中的费率展示。
    function feeToPercentString(uint24 fee) internal pure returns (string memory) {
        if (fee == 0) {
            return '0%';
        }
        uint24 temp = fee;
        uint256 digits;
        uint8 numSigfigs;
        while (temp != 0) {
            if (numSigfigs > 0) {
                // count all digits preceding least significant figure
                numSigfigs++;
            } else if (temp % 10 != 0) {
                numSigfigs++;
            }
            digits++;
            temp /= 10;
        }

        DecimalStringParams memory params;
        uint256 nZeros;
        if (digits >= 5) {
            // if decimal > 1 (5th digit is the ones place)
            uint256 decimalPlace = digits.sub(numSigfigs) >= 4 ? 0 : 1;
            nZeros = digits.sub(5) < (numSigfigs.sub(1)) ? 0 : digits.sub(5).sub(numSigfigs.sub(1));
            params.zerosStartIndex = numSigfigs;
            params.zerosEndIndex = uint8(params.zerosStartIndex.add(nZeros).sub(1));
            params.sigfigIndex = uint8(params.zerosStartIndex.sub(1).add(decimalPlace));
            params.bufferLength = uint8(nZeros.add(numSigfigs.add(1)).add(decimalPlace));
        } else {
            // else if decimal < 1
            nZeros = uint256(5).sub(digits);
            params.zerosStartIndex = 2;
            params.zerosEndIndex = uint8(nZeros.add(params.zerosStartIndex).sub(1));
            params.bufferLength = uint8(nZeros.add(numSigfigs.add(2)));
            params.sigfigIndex = uint8((params.bufferLength).sub(2));
            params.isLessThanOne = true;
        }
        params.sigfigs = uint256(fee).div(10**(digits.sub(numSigfigs)));
        params.isPercent = true;
        params.decimalIndex = digits > 4 ? uint8(digits.sub(4)) : 0;

        return generateDecimalString(params);
    }

    /// @notice 地址转十六进制字符串（0x 前缀）。
    function addressToString(address addr) internal pure returns (string memory) {
        return (uint256(addr)).toHexString(20);
    }

    /// @notice 生成 SVG 图像文本。
    /// @param params tokenURI 的构图参数。
    /// @return svg 完整 SVG 字符串。
    /// @dev 核心逻辑（逐行理解）：
    /// 1) 构造 `NFTSVG.SVGParams`；
    /// 2) 颜色由 token 地址切片生成，保证同一交易对风格稳定；
    /// 3) 圆点坐标由 token 地址 + tokenId 计算，保证“同池不同 NFT”有细微差异；
    /// 4) 调 `NFTSVG.generateSVG` 输出最终图片。
    /// @dev 例子：同样是 USDT/WBNB 池，不同 tokenId 的背景斑点位置会不同，便于视觉区分。
    function generateSVGImage(ConstructTokenURIParams memory params) internal pure returns (string memory svg) {
        NFTSVG.SVGParams memory svgParams =
        NFTSVG.SVGParams({
        quoteToken: addressToString(params.quoteTokenAddress),
        baseToken: addressToString(params.baseTokenAddress),
        poolAddress: params.poolAddress,
        quoteTokenSymbol: params.quoteTokenSymbol,
        baseTokenSymbol: params.baseTokenSymbol,
        feeTier: feeToPercentString(params.fee),
        tickLower: params.tickLower,
        tickUpper: params.tickUpper,
        tickSpacing: params.tickSpacing,
        overRange: overRange(params.tickLower, params.tickUpper, params.tickCurrent),
        tokenId: params.tokenId,
        color0: tokenToColorHex(uint256(params.quoteTokenAddress), 136),
        color1: tokenToColorHex(uint256(params.baseTokenAddress), 136),
        color2: tokenToColorHex(uint256(params.quoteTokenAddress), 0),
        color3: tokenToColorHex(uint256(params.baseTokenAddress), 0),
        x1: scale(getCircleCoord(uint256(params.quoteTokenAddress), 16, params.tokenId), 0, 255, 16, 274),
        y1: scale(getCircleCoord(uint256(params.baseTokenAddress), 16, params.tokenId), 0, 255, 100, 484),
        x2: scale(getCircleCoord(uint256(params.quoteTokenAddress), 32, params.tokenId), 0, 255, 16, 274),
        y2: scale(getCircleCoord(uint256(params.baseTokenAddress), 32, params.tokenId), 0, 255, 100, 484),
        x3: scale(getCircleCoord(uint256(params.quoteTokenAddress), 48, params.tokenId), 0, 255, 16, 274),
        y3: scale(getCircleCoord(uint256(params.baseTokenAddress), 48, params.tokenId), 0, 255, 100, 484)
        });

        return NFTSVG.generateSVG(svgParams);
    }

    /// @notice 判断当前价格相对仓位区间的位置。
    /// @return -1: 当前价在区间下方；0: 区间内；1: 区间上方。
    /// @dev 使用场景：SVG 里显示仓位是否“in range”。
    function overRange(
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent
    ) private pure returns (int8) {
        if (tickCurrent < tickLower) {
            return -1;
        } else if (tickCurrent > tickUpper) {
            return 1;
        } else {
            return 0;
        }
    }

    /// @notice 线性映射数值范围（用于 SVG 坐标缩放）。
    /// @dev 例子：把 0~255 映射到画布 x 轴 16~274。
    function scale(
        uint256 n,
        uint256 inMn,
        uint256 inMx,
        uint256 outMn,
        uint256 outMx
    ) private pure returns (string memory) {
        return (n.sub(inMn).mul(outMx.sub(outMn)).div(inMx.sub(inMn)).add(outMn)).toString();
    }

    /// @notice 从 token 地址中切片生成 3 字节颜色（hex）。
    function tokenToColorHex(uint256 token, uint256 offset) internal pure returns (string memory str) {
        return string((token >> offset).toHexStringNoPrefix(3));
    }

    /// @notice 计算 SVG 圆点坐标原始值（0~254）。
    /// @dev 例子：token 地址片段 * tokenId 后取模 255，保证分布看起来随机但可复现。
    function getCircleCoord(
        uint256 tokenAddress,
        uint256 offset,
        uint256 tokenId
    ) internal pure returns (uint256) {
        return (sliceTokenHex(tokenAddress, offset) * tokenId) % 255;
    }

    /// @notice 从地址中取某 1 字节切片。
    function sliceTokenHex(uint256 token, uint256 offset) internal pure returns (uint256) {
        return uint256(uint8(token >> offset));
    }

    /// @notice 转移管理员权限。
    /// @param _owner 新管理员地址。
    /// @dev 使用场景：项目多签接管 descriptor 管理权限。
    function setOwner(address _owner) external onlyOwner {
        // 先更新 owner，再发事件（沿用当前合约既有写法）。
        owner = _owner;

        emit OwnerChanged(owner, _owner);
    }

    /// @notice 切换 tokenURI 返回模式，并更新 HTTP 域名前缀。
    /// @param _switchToHttpLink true=返回 `NFTDomain/dataURI`，false=直接返回 dataURI。
    /// @param _NFTDomain 域名前缀字符串。
    /// @dev 使用场景：前端想走统一网关 CDN，可设 true + 自有域名；链上纯展示可设 false。
    function toggleSwitchAndUpdateNFTDomain(bool _switchToHttpLink, string memory _NFTDomain) external onlyOwner {
        switchToHttpLink = _switchToHttpLink;
        NFTDomain = _NFTDomain;

        emit ToggleSwitchAndUpdateNFTDomain(msg.sender, _switchToHttpLink, _NFTDomain);
    }
}