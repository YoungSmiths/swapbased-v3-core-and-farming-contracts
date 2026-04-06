// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

/// @title BlockTimestamp —— 可测试的「当前时间」抽象
/// @notice 默认返回 `block.timestamp`；单元测试里可覆写为固定时间，便于测 deadline、permit 过期等。
abstract contract BlockTimestamp {
    /// @notice 当前区块时间戳（秒）。
    /// @return 默认 `block.timestamp`。
    /// **使用场景**：`PeripheryValidation.checkDeadline`、`ERC721Permit.permit` 的 `deadline` 校验。
    function _blockTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }
}
