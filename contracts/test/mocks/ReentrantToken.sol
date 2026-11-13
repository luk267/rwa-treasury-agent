// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";

/// @title ReentrantToken
/// @notice Test-only ERC-20 that calls back into the vault while the vault is sending it.
/// @dev When the vault calls `transfer`, the token first calls `executeTransfer` for the same
///      recipient and amount, then completes the outer transfer. Only useful if the test gives
///      the token AGENT_ROLE. Without a re-entrancy guard, both calls see the same daily
///      counter and the recipient gets the amount twice.
contract ReentrantToken is ERC20 {
    TreasuryVault public immutable VAULT;

    bool private _entered;

    /// @notice Mints the whole supply to the deployer.
    /// @param vault The vault to call back into.
    constructor(TreasuryVault vault) ERC20("Reentrant", "REENTER") {
        VAULT = vault;
        _mint(msg.sender, 1_000_000e18);
    }

    /// @notice Re-enter the vault once if the vault is the caller, then transfer as usual.
    /// @param to The recipient.
    /// @param value The amount.
    /// @return Always true; failures revert, including a failed re-entry.
    function transfer(address to, uint256 value) public override returns (bool) {
        if (msg.sender == address(VAULT) && !_entered) {
            _entered = true;
            VAULT.executeTransfer(address(this), to, value);
            _entered = false;
        }
        return super.transfer(to, value);
    }
}
