// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

interface IGridTaxReceiver {
    function token() external view returns (address);
    function treasury() external view returns (address);
    function onTaxReceived(uint256 rewards, uint256 resources) external;
}

/// @title Swarm Cities launch token
/// @notice Fixed initial supply of GRID; every transfer pays a 4% tax, rounded down.
/// @dev Minting and explicit burns are not transfers. Pool shares are escrowed until the
/// deployer permanently binds the registry; there is no tax exemption or tax-rate switch.
contract LaunchToken is ERC20, ERC20Burnable {
    uint256 public constant TAX_BPS = 400;
    address public constant TREASURY = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address public immutable deployer;
    address public cityRegistry;
    uint256 public pendingRewards;
    uint256 public pendingResources;

    error Unauthorized();
    error RegistryAlreadySet();
    error InvalidRegistry();

    event CityRegistrySet(address indexed registry);
    event TaxTaken(
        address indexed from,
        address indexed to,
        uint256 grossAmount,
        uint256 fee,
        uint256 rewards,
        uint256 resources,
        uint256 burned,
        uint256 treasuryAmount
    );

    constructor() ERC20("Swarm Cities", "GRID") {
        deployer = msg.sender;
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }

    /// @notice Bind the reviewed registry once and deliver all previously escrowed pool shares.
    /// @dev The deploying factory must support this call. Getters check wiring, not code authenticity.
    function setCityRegistry(address registry) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (cityRegistry != address(0)) revert RegistryAlreadySet();
        if (registry == address(0) || registry == address(this) || registry.code.length == 0) {
            revert InvalidRegistry();
        }
        if (
            IGridTaxReceiver(registry).token() != address(this)
                || IGridTaxReceiver(registry).treasury() != TREASURY
        ) revert InvalidRegistry();
        cityRegistry = registry;
        uint256 rewards = pendingRewards;
        uint256 resources = pendingResources;
        pendingRewards = 0;
        pendingResources = 0;
        emit CityRegistrySet(registry);
        if (rewards + resources != 0) {
            super._update(address(this), registry, rewards + resources);
            IGridTaxReceiver(registry).onTaxReceived(rewards, resources);
        }
    }

    /// @notice floor(amount * TAX_BPS / 10_000), without multiplication overflow.
    function transferTax(uint256 amount) public pure returns (uint256) {
        return amount / (10_000 / TAX_BPS);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }
        // Check the gross debit even when sender, recipient or a beneficiary coincide.
        uint256 balance = balanceOf(from);
        if (balance < amount) revert ERC20InsufficientBalance(from, balance, amount);
        uint256 fee = transferTax(amount);
        uint256 resources = fee * 3 / 10;
        uint256 burned = fee / 10;
        uint256 treasuryAmount = burned;
        uint256 rewards = fee - resources - burned - treasuryAmount;
        address registry = cityRegistry;

        // Base updates allocate a single tax; internal settlement never recursively taxes itself.
        super._update(from, to, amount - fee);
        if (burned != 0) super._update(from, address(0), burned);
        if (treasuryAmount != 0) super._update(from, TREASURY, treasuryAmount);
        if (rewards + resources != 0) {
            super._update(from, registry == address(0) ? address(this) : registry, rewards + resources);
            if (registry == address(0)) {
                pendingRewards += rewards;
                pendingResources += resources;
            }
        }
        emit TaxTaken(from, to, amount, fee, rewards, resources, burned, treasuryAmount);
        if (registry != address(0) && rewards + resources != 0) {
            IGridTaxReceiver(registry).onTaxReceived(rewards, resources);
        }
    }
}
