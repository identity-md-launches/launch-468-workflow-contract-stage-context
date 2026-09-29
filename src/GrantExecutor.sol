// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The only city operations an executor may forward.
interface ICityGrants {
    function grantResources(uint256 cityId, uint256 amount) external;

    function recordHeartbeat(
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    ) external;
}

/// @notice An immutable operator forwards resource grants to city registries.
/// @dev Registry targets are supplied per call so registries can be deployed afterwards
///      with this executor as their immutable authority. Pausing affects grants only.
contract GrantExecutor {
    error InvalidOperator();
    error Unauthorized();
    error GrantsPaused();
    error InvalidRegistry();
    error AlreadyPaused();
    error NotPaused();

    event GrantsPauseChanged(bool paused);

    address public immutable operator;
    bool public paused;

    constructor(address operator_) {
        if (operator_ == address(0)) revert InvalidOperator();
        operator = operator_;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert Unauthorized();
        _;
    }

    modifier grantsActive(address registry) {
        if (paused) revert GrantsPaused();
        if (registry.code.length == 0) revert InvalidRegistry();
        _;
    }

    function grantResources(address registry, uint256 cityId, uint256 amount)
        external
        onlyOperator
        grantsActive(registry)
    {
        ICityGrants(registry).grantResources(cityId, amount);
    }

    function recordHeartbeat(
        address registry,
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    ) external onlyOperator grantsActive(registry) {
        ICityGrants(registry).recordHeartbeat(cityId1, amount1, cityId2, amount2, cityId3, amount3);
    }

    function pause() external onlyOperator {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit GrantsPauseChanged(true);
    }

    function unpause() external onlyOperator {
        if (!paused) revert NotPaused();
        paused = false;
        emit GrantsPauseChanged(false);
    }
}
