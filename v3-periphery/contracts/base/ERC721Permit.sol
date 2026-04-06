// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/utils/Address.sol';

import '../libraries/ChainId.sol';
import '../interfaces/external/IERC1271.sol';
import '../interfaces/IERC721Permit.sol';
import './BlockTimestamp.sol';

/// @title ERC721Permit —— 支持 EIP-2612 风格链下签名的 ERC721
/// @notice 用户可离线签 `Permit(spender, tokenId, nonce, deadline)`，第三方代提交 `permit`，**无需先链上 `approve`**，适合与 `multicall` 组合。
///
/// **形象理解**：像 ERC20 的 permit，但授权对象是「某枚 NFT 给某 spender」；合约账户可用 ERC1271 `isValidSignature`。
abstract contract ERC721Permit is BlockTimestamp, ERC721, IERC721Permit {
    /// @notice 取该 `tokenId` 当前 nonce 并 +1（防签名重放）；子类实现（如 NPM 存在 `Position.nonce`）。
    function _getAndIncrementNonce(uint256 tokenId) internal virtual returns (uint256);

    /// @notice `DOMAIN_SEPARATOR` 里用的 name 的 keccak。
    bytes32 private immutable nameHash;

    /// @notice `DOMAIN_SEPARATOR` 里用的 version 的 keccak（如 "1"）。
    bytes32 private immutable versionHash;

    /// @param name_ NFT 名称（如 Pancake V3 Positions NFT-V1）。
    /// @param symbol_ 符号。
    /// @param version_ EIP-712 版本字符串，参与 DOMAIN 分隔符。
    constructor(
        string memory name_,
        string memory symbol_,
        string memory version_
    ) ERC721(name_, symbol_) {
        nameHash = keccak256(bytes(name_));
        versionHash = keccak256(bytes(version_));
    }

    /// @notice EIP-712 域分隔符（含 chainId、本合约地址），用于 `permit` 验签。
    /// @inheritdoc IERC721Permit
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    // keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
                    0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
                    nameHash,
                    versionHash,
                    ChainId.get(),
                    address(this)
                )
            );
    }

    /// @notice Permit 结构体类型哈希（spender、tokenId、nonce、deadline）。
    /// @inheritdoc IERC721Permit
    bytes32 public constant override PERMIT_TYPEHASH =
        0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    /// @notice 用签名授权 `spender` 操作 `tokenId`（等价于 `approve`，但链下完成）。
    /// @param spender 被授权地址（如 Router）。
    /// @param tokenId 头寸 NFT id。
    /// @param deadline 签名过期时间。
    /// @param v, r, s ECDSA 或合约签名。
    /// **核心逻辑**：验 `deadline` → 拼 digest → owner 为合约则 ERC1271，否则 `ecrecover` → `_approve`。
    /// **使用场景**：聚合器代用户 `decreaseLiquidity` / `collect` 前先 `permit`。
    /// @inheritdoc IERC721Permit
    function permit(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable override {
        require(_blockTimestamp() <= deadline, 'Permit expired');

        bytes32 digest =
            keccak256(
                abi.encodePacked(
                    '\x19\x01',
                    DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, _getAndIncrementNonce(tokenId), deadline))
                )
            );
        address owner = ownerOf(tokenId);
        require(spender != owner, 'ERC721Permit: approval to current owner');

        if (Address.isContract(owner)) {
            require(IERC1271(owner).isValidSignature(digest, abi.encodePacked(r, s, v)) == 0x1626ba7e, 'Unauthorized');
        } else {
            address recoveredAddress = ecrecover(digest, v, r, s);
            require(recoveredAddress != address(0), 'Invalid signature');
            require(recoveredAddress == owner, 'Unauthorized');
        }

        _approve(spender, tokenId);
    }
}
