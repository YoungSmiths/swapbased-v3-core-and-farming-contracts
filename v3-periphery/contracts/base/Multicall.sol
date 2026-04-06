// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '../interfaces/IMulticall.sol';

/// @title Multicall —— 单次交易内批量调用本合约多个函数
/// @notice 通过 `delegatecall` 依次执行 `data[i]`，把「授权 + mint + 其他操作」打成一包，省 gas、原子成功或失败。
///
/// **形象理解**：像一次「批量执行脚本」，每条 `data` 是对本合约某函数的 ABI 编码调用数据；全部在同一合约上下文中跑完。
///
/// **核心逻辑**：`address(this).delegatecall` → 失败则尝试把 revert reason 解码成字符串再抛出，便于前端展示。
///
/// **使用场景**：`NonfungiblePositionManager` 里先 `selfPermit` 再 `mint`；或 SwapRouter 里多跳 swap + 退款。
/// **注意**：`msg.sender` 在各子调用中仍是**用户**（与外部调用一致），但需理解 delegatecall 的存储与上下文。
abstract contract Multicall is IMulticall {
    /// @notice 批量执行调用。
    /// @param data 每项为 `abi.encodeWithSelector(...)` 等编码后的 calldata，目标均为本合约。
    /// @return results 每项为对应调用的 `return data`（成功时）。
    /// **实际案例**：`[selfPermit.selector+..., mint.selector+...]`，一笔交易完成 permit + 加流动性。
    /// @inheritdoc IMulticall
    function multicall(bytes[] calldata data) public payable override returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // Next 5 lines from https://ethereum.stackexchange.com/a/83577
                if (result.length < 68) revert();
                assembly {
                    result := add(result, 0x04)
                }
                revert(abi.decode(result, (string)));
            }

            results[i] = result;
        }
    }
}
