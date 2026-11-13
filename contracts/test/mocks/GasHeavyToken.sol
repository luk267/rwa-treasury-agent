// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title GasHeavyToken
/// @notice Test-only ERC-20 whose `transfer` burns a fixed amount of gas before it moves tokens.
/// @dev Stands in for a token with expensive compliance checks. With a tight gas limit the
///      token runs out of gas while its caller keeps 1/64 of the gas (EIP-150).
contract GasHeavyToken is ERC20 {
    /// @notice Gas burned by every `transfer` before the balance update.
    uint256 public constant BURN_GAS = 500_000;

    /// @notice Mints the whole supply to the deployer.
    constructor() ERC20("Gas Heavy", "HEAVY") {
        _mint(msg.sender, 1_000_000e18);
    }

    /// @notice Burn BURN_GAS, then transfer as usual. Runs out of gas if less is left.
    /// @param to The recipient.
    /// @param value The amount.
    /// @return Always true; failures revert.
    function transfer(address to, uint256 value) public override returns (bool) {
        uint256 start = gasleft();
        while (start - gasleft() < BURN_GAS) { }
        return super.transfer(to, value);
    }
}
