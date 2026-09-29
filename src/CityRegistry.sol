// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGridToken} from "./interfaces/IGridToken.sol";
import {GrantExecutor} from "./GrantExecutor.sol";

/// @notice Soulbound cities, weighted rewards, and nonredeemable resources backed by GRID.
/// @dev The bound GRID token credits its transfer-tax shares through onTaxReceived.
contract CityRegistry is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant GRID_UNIT = 1e18;
    uint256 public constant GRID_SIZE = 16;
    uint256 public constant CITY_COUNT = 256;
    uint256 public constant MAX_LEVEL = 20;
    uint256 public constant MIN_HOLDING = 1000e18;
    uint256 public constant REWARD_SCALE = 1e27;

    struct City {
        address owner;
        uint256 level;
        uint256 resources;
        uint256 rewardIndex;
        uint256 accruedScaled;
    }

    IERC20 public immutable token;
    GrantExecutor public immutable grantExecutor;
    address public immutable treasury;
    City[256] public cities;
    /// @notice Zero means no city; otherwise this is cityId + 1, including plot zero.
    mapping(address => uint256) public cityOf;
    uint256 public soldPlots;
    uint256 public totalWeight;
    uint256 public rewardsPool;
    uint256 public resourcePot;
    /// @notice GRID backing unspent granted resources; burned as leveling consumes those resources.
    uint256 public allocatedResourceBacking;
    uint256 public accRewardPerWeight;
    uint256 public rewardRemainder;
    uint256 public queuedRewards;
    uint256 public heartbeatCount;
    uint256 public lastHeartbeatTimestamp;
    uint256[3] public lastHeartbeatCityIds;
    uint256[3] public lastHeartbeatAmounts;

    error InvalidToken();
    error InvalidExecutor();
    error InvalidCityId();
    error CityOccupied();
    error AlreadyOwnsCity();
    error InsufficientHolding();
    error NotCityOwner();
    error CityNotOwned();
    error MaximumLevel();
    error InsufficientResources();
    error UnauthorizedExecutor();
    error InvalidAmount();
    error InsufficientResourcePot();
    error DuplicateWinners();
    error NoRewards();
    error InvalidRecipient();
    error UnexpectedTokenAmount();
    error SoldOut();
    error UnauthorizedToken();

    event CityBought(uint256 indexed cityId, address indexed owner, uint256 price);
    event ResourcesGranted(uint256 indexed cityId, uint256 amount);
    event CityLeveled(uint256 indexed cityId, uint256 level, uint256 resourcesConsumed);
    event RewardsClaimed(uint256 indexed cityId, address indexed owner, uint256 amount);
    event PoolsFunded(address indexed funder, uint256 rewards, uint256 resources);
    event TransferTaxReceived(uint256 rewards, uint256 resources);
    event HeartbeatRecorded(uint256 indexed sequence, uint256[3] cityIds, uint256[3] amounts);

    constructor(address token_, address grantExecutor_) {
        if (token_.code.length == 0 || IGridToken(token_).decimals() != 18) revert InvalidToken();
        if (grantExecutor_.code.length == 0) revert InvalidExecutor();
        address operator = GrantExecutor(grantExecutor_).operator();
        if (operator == address(0)) revert InvalidExecutor();
        token = IERC20(token_);
        grantExecutor = GrantExecutor(grantExecutor_);
        treasury = operator;
    }

    modifier onlyExecutor() {
        if (msg.sender != address(grantExecutor)) revert UnauthorizedExecutor();
        _;
    }

    function coordinates(uint256 cityId) external pure returns (uint256 x, uint256 y) {
        _validId(cityId);
        return (cityId % GRID_SIZE, cityId / GRID_SIZE);
    }

    /// @notice Price in minor GRID units. Multiplication precedes division.
    function cityPrice() public view returns (uint256) {
        if (soldPlots == CITY_COUNT) revert SoldOut();
        uint256 n = CITY_COUNT + soldPlots;
        return 10_000 * GRID_UNIT * n * n / 65_536;
    }

    /// @notice Approve exactly the displayed quote; a stale quote then reverts. Payment is burned in full.
    /// @dev An oversized allowance permits burning the higher live price after intervening purchases.
    function buyCity(uint256 cityId) external nonReentrant {
        _validId(cityId);
        City storage city = cities[cityId];
        if (city.owner != address(0)) revert CityOccupied();
        if (cityOf[msg.sender] != 0) revert AlreadyOwnsCity();
        if (token.balanceOf(msg.sender) < MIN_HOLDING) revert InsufficientHolding();
        uint256 price = cityPrice();
        city.owner = msg.sender;
        city.level = 1;
        city.rewardIndex = accRewardPerWeight;
        cityOf[msg.sender] = cityId + 1;
        ++soldPlots;
        ++totalWeight;
        // Before the first city, rewards wait in the pool. The first city receives that queue.
        if (queuedRewards != 0) {
            uint256 queued = queuedRewards;
            queuedRewards = 0;
            _distribute(queued);
        }
        emit CityBought(cityId, msg.sender, price);
        // The guard blocks callbacks; a failed burn also rolls back the purchase and event.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IGridToken(address(token)).burnFrom(msg.sender, price);
    }

    function levelUpCost(uint256 cityId) public view returns (uint256) {
        _existingCity(cityId);
        uint256 next = cities[cityId].level + 1;
        if (next > MAX_LEVEL) revert MaximumLevel();
        return 100 * next * next;
    }

    function levelUp(uint256 cityId) external nonReentrant {
        City storage city = _ownedCity(cityId);
        uint256 cost = levelUpCost(cityId);
        if (city.resources < cost) revert InsufficientResources();
        _settle(city);
        city.resources -= cost;
        uint256 backing = cost * GRID_UNIT;
        allocatedResourceBacking -= backing;
        totalWeight += 2 * city.level + 1;
        ++city.level;
        emit CityLeveled(cityId, city.level, cost);
        // Consumed resources no longer require custody; a failed burn rolls back the entire level change.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IGridToken(address(token)).burn(backing);
    }

    function claimableRewards(uint256 cityId) public view returns (uint256) {
        _validId(cityId);
        City storage city = cities[cityId];
        return (city.accruedScaled + city.level * city.level * (accRewardPerWeight - city.rewardIndex))
            / REWARD_SCALE;
    }

    /// @notice Fractional minor units stay credited to the city across claims and level changes.
    function claimRewards(uint256 cityId) external nonReentrant returns (uint256 amount) {
        City storage city = _ownedCity(cityId);
        _settle(city);
        amount = city.accruedScaled / REWARD_SCALE;
        if (amount == 0) revert NoRewards();
        city.accruedScaled %= REWARD_SCALE;
        rewardsPool -= amount;
        token.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(cityId, msg.sender, amount);
    }

    /// @notice Credit the net funding receipt, in addition to the token's automatic tax shares.
    function fundRewards(uint256 amount) external nonReentrant {
        uint256 received = _pull(amount);
        rewardsPool += received;
        _distribute(received);
        emit PoolsFunded(msg.sender, received, 0);
    }

    function fundResources(uint256 amount) external nonReentrant {
        uint256 received = _pull(amount);
        resourcePot += received;
        emit PoolsFunded(msg.sender, 0, received);
    }

    /// @notice Compatibility route that forwards one universally taxed token transfer.
    function transferWithTax(address to, uint256 amount) external nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        token.safeTransferFrom(msg.sender, to, amount);
    }

    /// @notice Account for pool shares already delivered by GRID, including taxes on claims.
    /// @dev Intentionally callable during a guarded funding/claim: token-only, no external calls.
    function onTaxReceived(uint256 rewards, uint256 resources) external {
        if (msg.sender != address(token)) revert UnauthorizedToken();
        rewardsPool += rewards;
        resourcePot += resources;
        _distribute(rewards);
        emit TransferTaxReceived(rewards, resources);
    }

    /// @notice Amount is in whole resources; each resource allocates one GRID from the resource pot.
    function grantResources(uint256 cityId, uint256 amount) external nonReentrant onlyExecutor {
        _grant(cityId, amount);
    }

    /// @notice Grants all three awards atomically. Winners must be distinct owned cities.
    function recordHeartbeat(
        uint256 cityId1,
        uint256 amount1,
        uint256 cityId2,
        uint256 amount2,
        uint256 cityId3,
        uint256 amount3
    ) external nonReentrant onlyExecutor {
        if (cityId1 == cityId2 || cityId1 == cityId3 || cityId2 == cityId3) {
            revert DuplicateWinners();
        }
        _grant(cityId1, amount1);
        _grant(cityId2, amount2);
        _grant(cityId3, amount3);
        lastHeartbeatCityIds = [cityId1, cityId2, cityId3];
        lastHeartbeatAmounts = [amount1, amount2, amount3];
        lastHeartbeatTimestamp = block.timestamp;
        ++heartbeatCount;
        emit HeartbeatRecorded(heartbeatCount, lastHeartbeatCityIds, lastHeartbeatAmounts);
    }

    function _grant(uint256 cityId, uint256 amount) private {
        _existingCity(cityId);
        if (amount == 0) revert InvalidAmount();
        if (amount > resourcePot / GRID_UNIT) revert InsufficientResourcePot();
        uint256 backing = amount * GRID_UNIT;
        resourcePot -= backing;
        allocatedResourceBacking += backing;
        cities[cityId].resources += amount;
        emit ResourcesGranted(cityId, amount);
    }

    function _pull(uint256 amount) private returns (uint256 received) {
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforePools = rewardsPool + resourcePot;
        received = amount - IGridToken(address(token)).transferTax(amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
        // Callback tax credits are already booked; only the net funding creates another liability.
        uint256 taxCredit = rewardsPool + resourcePot - beforePools;
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (token.balanceOf(address(this)) != beforeBalance + received + taxCredit) {
            revert UnexpectedTokenAmount();
        }
    }

    function _distribute(uint256 amount) private {
        if (totalWeight == 0) {
            queuedRewards += amount;
            return;
        }
        uint256 numerator = amount * REWARD_SCALE + rewardRemainder;
        accRewardPerWeight += numerator / totalWeight;
        rewardRemainder = numerator % totalWeight;
    }

    function _settle(City storage city) private {
        city.accruedScaled += city.level * city.level * (accRewardPerWeight - city.rewardIndex);
        city.rewardIndex = accRewardPerWeight;
    }

    function _ownedCity(uint256 cityId) private view returns (City storage city) {
        _validId(cityId);
        city = cities[cityId];
        if (city.owner != msg.sender) revert NotCityOwner();
    }

    function _existingCity(uint256 cityId) private view {
        _validId(cityId);
        if (cities[cityId].owner == address(0)) revert CityNotOwned();
    }

    function _validId(uint256 cityId) private pure {
        if (cityId >= CITY_COUNT) revert InvalidCityId();
    }
}
