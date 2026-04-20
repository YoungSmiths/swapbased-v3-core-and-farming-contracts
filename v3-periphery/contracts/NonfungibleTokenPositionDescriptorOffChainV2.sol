// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts-upgradeable/proxy/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol';

import './interfaces/INonfungibleTokenPositionDescriptor.sol';

/// @title NonfungibleTokenPositionDescriptorOffChainV2
/// @notice OffChain 描述器 V2：支持 `initialize` + 一次性 `initializeV2`，便于升级后重设 URI。
/// @dev 使用场景：老版本已初始化后，发布新实现希望再改一次 `_baseTokenURI`，可调用 `initializeV2`。
contract NonfungibleTokenPositionDescriptorOffChainV2 is INonfungibleTokenPositionDescriptor, Initializable {
    using StringsUpgradeable for uint256;

    /// @notice tokenURI 前缀（链下 metadata 服务地址）。
    string private _baseTokenURI;

    /// @notice 记录 V2 是否已初始化，防止 `initializeV2` 被重复调用。
    bool private _initializedV2;

    /// @notice 限制 `initializeV2` 只能执行一次。
    /// @dev 例子：升级后首次设置新 URI 成功；第二次再调会 revert `Already initialized V2`。
    modifier initializerV2() {
        require(!_initializedV2, "Already initialized V2");

        _initializedV2 = true;

        _;
    }

    /// @notice V1 初始化（遵循 OpenZeppelin `initializer` 约束）。
    /// @param baseTokenURI tokenURI 前缀。
    /// @dev 使用场景：首次部署代理时设置默认链下 metadata 地址。
    function initialize(string calldata baseTokenURI) external initializer {
        _baseTokenURI = baseTokenURI;
    }

    /// @notice V2 一次性初始化入口，用于升级后重新设置 URI。
    /// @param baseTokenURI 新的 tokenURI 前缀。
    /// @dev 使用场景：迁移到新域名（例如从旧 CDN 切换到新网关）。
    function initializeV2(string calldata baseTokenURI) external initializerV2 {
        _baseTokenURI = baseTokenURI;
    }

    /// @inheritdoc INonfungibleTokenPositionDescriptor
    /// @notice 返回链下模式 tokenURI。
    /// @param positionManager 保留接口参数，本实现未使用。
    /// @param tokenId LP NFT 编号。
    /// @return 若 `_baseTokenURI` 非空，返回 `base + tokenId`；否则返回空字符串。
    /// @dev 例子：`base=https://meta.swapbased.com/v2/`，`tokenId=88` -> `https://meta.swapbased.com/v2/88`。
    function tokenURI(INonfungiblePositionManager positionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        return bytes(_baseTokenURI).length > 0 ? string(abi.encodePacked(_baseTokenURI, tokenId.toString())) : "";
    }
}
