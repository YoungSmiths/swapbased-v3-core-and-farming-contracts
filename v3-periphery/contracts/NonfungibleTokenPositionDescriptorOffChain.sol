// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts-upgradeable/proxy/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol';

import './interfaces/INonfungibleTokenPositionDescriptor.sol';

/// @title NonfungibleTokenPositionDescriptorOffChain
/// @notice 轻量版离线描述器：仅返回 `baseTokenURI + tokenId`，由链下服务提供 metadata。
/// @dev 使用场景：项目希望将 JSON/SVG 托管到自己的网关或 CDN，而非链上拼接大字符串。
contract NonfungibleTokenPositionDescriptorOffChain is INonfungibleTokenPositionDescriptor, Initializable {
    using StringsUpgradeable for uint256;

    /// @notice tokenURI 前缀（例如 `https://nft.swapbased.xyz/position/`）。
    string private _baseTokenURI;

    /// @notice 初始化函数（可升级合约模式）。
    /// @param baseTokenURI tokenURI 前缀。
    /// @dev 使用场景：代理部署后，由管理员调用一次设置元数据服务地址。
    function initialize(string calldata baseTokenURI) external initializer {
        _baseTokenURI = baseTokenURI;
    }

    /// @inheritdoc INonfungibleTokenPositionDescriptor
    /// @notice 返回链下模式 tokenURI。
    /// @param positionManager 保留接口参数，本实现未使用。
    /// @param tokenId LP NFT 编号。
    /// @return 若 `_baseTokenURI` 非空，则返回 `base + tokenId`；否则返回空字符串。
    /// @dev 例子：`base=https://api.swap.xyz/nft/`、`tokenId=123`，返回 `https://api.swap.xyz/nft/123`。
    function tokenURI(INonfungiblePositionManager positionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        return bytes(_baseTokenURI).length > 0 ? string(abi.encodePacked(_baseTokenURI, tokenId.toString())) : "";
    }
}
