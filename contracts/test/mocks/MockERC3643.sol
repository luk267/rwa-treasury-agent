// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title MockERC3643
/// @notice Test-only ERC-20 that models the ERC-3643 rules the Treasury Vault touches:
///         recipient identity, wallet freeze, token pause, a compliance verdict, and the
///         issuer's forced transfer.
/// @dev Checks run in the order of T-REX v5 (`ERC3643Token._update` on `develop`):
///      pause, frozen sender, frozen recipient, balance, recipient identity, compliance.
///      Reverts use the v5 error names. The identity registry and the compliance contract
///      are stubbed as flags. "Agent" in ERC-3643 means the issuer's operator, so the
///      privileged account is called ISSUER_AGENT here. Not production-grade.
contract MockERC3643 is ERC20, Pausable {
    /// @notice The recipient is not verified in the (stubbed) identity registry.
    error UnverifiedIdentity();
    /// @notice The (stubbed) compliance contract refused the transfer.
    error ComplianceNotFollowed();
    /// @notice `wallet` is frozen by the issuer.
    error FrozenWallet(address wallet);
    /// @notice The caller is not the issuer's agent.
    error NotIssuerAgent();

    /// @notice Issuer-side operator ("agent" in ERC-3643 terms). Set to the deployer.
    address public immutable ISSUER_AGENT;

    mapping(address => bool) private _verified;
    mapping(address => bool) private _frozen;
    bool private _complianceOk = true;

    event VerificationSet(address indexed wallet, bool verified);
    event AddressFrozen(address indexed wallet, bool indexed frozen, address indexed owner);
    event ComplianceSet(bool ok);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);

    modifier onlyIssuerAgent() {
        _checkIssuerAgent();
        _;
    }

    /// @notice Makes the deployer the issuer's agent, verifies it, and mints it the supply.
    /// @dev The deployer is verified first, otherwise the identity check blocks the mint.
    constructor() ERC20("Mock RWA", "MOCK") {
        ISSUER_AGENT = msg.sender;
        _verified[msg.sender] = true;
        emit VerificationSet(msg.sender, true);
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    /// @notice Stub for the identity registry: mark `wallet` as verified or not.
    /// @param wallet The wallet to update.
    /// @param verified True if the wallet passed KYC and may receive tokens.
    function setVerified(address wallet, bool verified) external onlyIssuerAgent {
        _verified[wallet] = verified;
        emit VerificationSet(wallet, verified);
    }

    /// @notice Whether `wallet` may receive tokens.
    /// @param wallet The wallet to query.
    /// @return True if the wallet is verified.
    function isVerified(address wallet) external view returns (bool) {
        return _verified[wallet];
    }

    /// @notice Freeze or unfreeze a wallet. A frozen wallet can neither send nor receive.
    /// @dev Same name and event as in the ERC-3643 interface.
    /// @param wallet The wallet to update.
    /// @param frozen True to freeze.
    function setAddressFrozen(address wallet, bool frozen) external onlyIssuerAgent {
        _frozen[wallet] = frozen;
        emit AddressFrozen(wallet, frozen, msg.sender);
    }

    /// @notice Whether `wallet` is frozen.
    /// @param wallet The wallet to query.
    /// @return True if the wallet is frozen.
    function isFrozen(address wallet) external view returns (bool) {
        return _frozen[wallet];
    }

    /// @notice Stub for the compliance contract: let all transfers pass or refuse all.
    /// @param ok False makes every transfer and mint revert with ComplianceNotFollowed.
    function setCompliance(bool ok) external onlyIssuerAgent {
        _complianceOk = ok;
        emit ComplianceSet(ok);
    }

    /// @notice Pause all transfers between wallets.
    function pause() external onlyIssuerAgent {
        _pause();
    }

    /// @notice Resume transfers.
    function unpause() external onlyIssuerAgent {
        _unpause();
    }

    /// @notice Move tokens from any holder without the holder's consent.
    /// @dev As in T-REX 4.1.6, only the recipient's identity is checked: no freeze and no
    ///      compliance check. T-REX v5 also blocks this while the token is paused; the mock
    ///      does not.
    /// @param from The holder to take tokens from.
    /// @param to The recipient. Must be verified.
    /// @param amount The amount to move.
    /// @return Always true; failures revert.
    function forcedTransfer(address from, address to, uint256 amount) external onlyIssuerAgent returns (bool) {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (!_verified[to]) revert UnverifiedIdentity();
        ERC20._update(from, to, amount);
        emit ForcedTransfer(from, to, amount);
        return true;
    }

    /// @dev Runs the ERC-3643 checks before every transfer and mint. Burns are not used here.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            _requireNotPaused();
            if (_frozen[from]) revert FrozenWallet(from);
            if (_frozen[to]) revert FrozenWallet(to);
            uint256 balance = balanceOf(from);
            if (value > balance) revert ERC20InsufficientBalance(from, balance, value);
        }
        if (!_verified[to]) revert UnverifiedIdentity();
        if (!_complianceOk) revert ComplianceNotFollowed();
        super._update(from, to, value);
    }

    function _checkIssuerAgent() private view {
        if (msg.sender != ISSUER_AGENT) revert NotIssuerAgent();
    }
}
