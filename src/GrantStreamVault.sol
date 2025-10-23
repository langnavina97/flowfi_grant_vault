// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Import IERC20 interface (only allowed dependency)
// Note: For production, use well-audited OpenZeppelin libraries:
// - Ownable2Step for enhanced ownership security
// - ReentrancyGuard for reentrancy protection
// - Upgradeable versions for proxy patterns
import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {MathUtils} from "./MathUtils.sol";

/// @title GrantStreamVault
/// @notice A minimal, gas-efficient vault for linearly distributing vested ERC20 DAO grants with a protocol fee.
/// @dev MVP version - see inline comments for production upgrade paths
contract GrantStreamVault {
    // --- Custom Errors ---
    // Using custom errors instead of require strings for gas efficiency
    error ZeroAddress();
    error InvalidFee();
    error ClaimsPaused();
    error GrantNotFound();
    error NoVestedFunds();
    error InvalidDuration();
    error InvalidAmount();
    error RecipientAlreadyHasGrant();
    error InvalidCliffDuration();
    error GrantInactive();
    error InvalidStartTime();
    error InsufficientAllowance();
    error NotOwner();
    error ReentrancyGuard();

    // --- State Variables ---

    // Core immutable parameters - set once at deployment for gas efficiency and security.
    // These cannot be changed after deployment, ensuring predictable behavior.
    uint16 public immutable PROTOCOL_FEE_BPS; // Protocol fee in basis points (1/10000). Max 500 (5%).
    address public immutable GRANT_TOKEN;
    
    // Production Note: For production, consider making fee recipient mutable with proper access control
    // to handle compromised addresses or operational changes. This MVP keeps it immutable for simplicity.
    // Add updateFeeRecipient function for production use
    address public immutable FEE_RECIPIENT;

    // Emergency pause mechanism - can halt all claims if needed.
    bool public paused;
    
    // Owner address for access control
    // Production: Use OpenZeppelin's Ownable2Step for enhanced security
    address public owner;
    
    // Reentrancy guard
    // Production: Use OpenZeppelin's ReentrancyGuard for well-audited protection
    uint256 private _status;

    // Grant data structure - tightly packed to minimize storage slots and gas costs.
    // Uses uint128 for amounts (supports up to ~3.4e38 tokens) and uint32 for timestamps.
    struct Grant {
        uint128 totalAmount;   // Total amount of tokens to vest
        uint128 claimedAmount; // Amount already claimed by the recipient
        uint32 startTime;      // Vesting start timestamp
        uint32 duration;       // Total vesting duration in seconds
        uint32 cliffDuration;  // Vesting cliff duration in seconds
        bool isActive;         // True if grant is currently active (not revoked)
        // Total: 16 + 16 + 4 + 4 + 4 + 1 = 45 bytes (fits in 2 storage slots)
    }

    // Production Note: For UUPS upgradeable contracts, add storage gap to prevent collisions:
    // uint256[50] private __gap;
    // This reserves storage slots for future variables without shifting existing storage layout.
    // Following EIP-1967, use well-known storage slots for proxy-specific data.

    // Maps each recipient address to their grant data.
    // Only one active grant per recipient is allowed in this MVP.
    mapping(address => Grant) public grants;

    // --- Modifiers ---
    modifier onlyWhenNotPaused() {
        if (paused) revert ClaimsPaused();
        _;
    }
    
    // Production: Use OpenZeppelin's Ownable2Step modifier
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    
    // Production: Use OpenZeppelin's ReentrancyGuard modifier
    modifier nonReentrant() {
        if (_status == 2) revert ReentrancyGuard();
        _status = 2;
        _;
        _status = 1;
    }

    // --- Constructor & Initialization ---

    /**
     * @notice Initializes the vault with immutable parameters for gas efficiency and security.
     * @dev For upgradeable contracts (UUPS), replace with `initialize()` function with initializer modifier.
     * @param _protocolFeeBps Protocol fee in basis points (max 500 = 5%)
     * @param _grantToken The ERC20 token that will be vested in grants
     * @param _feeRecipient Address that receives protocol fees
     * @param _owner Owner address with administrative privileges
     */
    constructor(
        uint16 _protocolFeeBps,
        address _grantToken,
        address _feeRecipient,
        address _owner
    ) {
        if (_grantToken == address(0) || _feeRecipient == address(0) || _owner == address(0)) 
            revert ZeroAddress();
        if (_protocolFeeBps > 500) revert InvalidFee();

        GRANT_TOKEN = _grantToken;
        PROTOCOL_FEE_BPS = _protocolFeeBps;
        FEE_RECIPIENT = _feeRecipient;
        owner = _owner;
        _status = 1; // Initialize reentrancy guard
    }

    // --- Events ---

    event GrantCreated(
        address indexed recipient,
        uint256 totalAmount,
        uint32 startTime,
        uint32 duration,
        uint32 cliffDuration
    );

    event GrantUpdated(
        address indexed recipient,
        uint256 newTotalAmount,
        uint256 additionalAmount,
        uint32 newDuration,
        uint32 newCliffDuration
    );

    event FundsClaimed(
        address indexed recipient,
        uint256 claimAmount,
        uint256 feeAmount,
        uint256 netAmount
    );

    event ClaimsPausedToggled(address indexed caller, bool newPausedState);
    
    event GrantRevoked(
        address indexed recipient, 
        uint256 vestedUnclaimed, 
        uint256 unvestedReturned
    );

    // --- Core Logic ---

    /**
     * @notice Calculates the total vested amount and available claim amount for a grant.
     * @param grant The grant to calculate for
     * @param recipient The recipient address (for vestedAmount calculation)
     * @return totalVested The total amount that has vested
     * @return availableToClaim The amount available to claim (0 if nothing available)
     */
    function _calculateVestedAndAvailable(Grant memory grant, address recipient) internal view returns (uint256 totalVested, uint256 availableToClaim) {
        if (grant.totalAmount == 0) {
            return (0, 0);
        }

        totalVested = grant.isActive 
            ? vestedAmount(recipient) 
            : grant.totalAmount; // Revoked grants: locked at revocation amount

        availableToClaim = totalVested > grant.claimedAmount 
            ? totalVested - grant.claimedAmount 
            : 0;
    }

    /**
     * @notice Calculates the protocol fee and net amount for a given claim amount.
     * @param amount The amount to calculate fees for
     * @return feeAmount The protocol fee amount
     * @return netAmount The amount after deducting the fee
     */
    function _calculateFeeAndNetAmount(uint256 amount) internal view returns (uint256 feeAmount, uint256 netAmount) {
        feeAmount = (amount * PROTOCOL_FEE_BPS) / 10000;
        netAmount = amount - feeAmount;
    }

    /**
     * @notice Calculates the total vested amount for a grant at the current time.
     * @dev Implements linear vesting with cliff support. Returns 0 if grant doesn't exist or before cliff.
     * @param recipient The address of the grant recipient
     * @return The total amount that has vested for this recipient
     */
    function vestedAmount(address recipient) public view returns (uint256) {
        Grant memory grant = grants[recipient];
        
        // Early returns for edge cases
        if (grant.totalAmount == 0) return 0; // No grant exists
        if (block.timestamp < grant.startTime) return 0; // Vesting hasn't started
        
        uint256 vestingTime = block.timestamp - grant.startTime;

        // Cliff period - nothing vests until cliff duration has passed
        if (vestingTime < grant.cliffDuration) {
            return 0;
        }

        // Cap vesting time at total duration to prevent over-vesting
        if (vestingTime >= grant.duration) {
            return grant.totalAmount; // Fully vested
        }

        // Linear vesting formula: (totalAmount * vestingTime) / duration
        // Multiply first to maintain precision, then divide
        return (uint256(grant.totalAmount) * vestingTime) / uint256(grant.duration);
    }

    /**
     * @notice View function to check how much a recipient can claim right now.
     * @param recipient The address of the grant recipient
     * @return feeAmount The protocol fee that will be charged
     * @return netAmount The amount the recipient will receive (after fees)
     */
    function claimableAmount(address recipient) external view returns (uint256 feeAmount, uint256 netAmount) {
        Grant memory grant = grants[recipient];
        (, uint256 availableToClaim) = _calculateVestedAndAvailable(grant, recipient);

        if (availableToClaim == 0) return (0, 0);

        // Return both fee and net amounts
        return _calculateFeeAndNetAmount(availableToClaim);
    }

    /**
     * @notice Owner creates a new grant for a recipient.
     * @dev Requires owner to approve tokens to this contract before calling.
     * @dev Only one grant per recipient allowed in this MVP.
     * @param recipient Address of the grant recipient
     * @param totalAmount Total tokens to vest over the duration
     * @param startTime When vesting begins (must be >= block.timestamp for safety)
     * @param duration Total vesting period in seconds
     * @param cliffDuration Cliff period in seconds (nothing vests before this)
     */
    function createGrant(
        address recipient,
        uint256 totalAmount,
        uint32 startTime,
        uint32 duration,
        uint32 cliffDuration
    ) external onlyOwner {
        // Input validation
        if (recipient == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();
        if (cliffDuration > duration) revert InvalidCliffDuration();
        
        // MVP: Prevent backdated grants for security and clarity
        // Production: If retroactive grants are needed, add explicit parameter and logic
        if (startTime < block.timestamp) revert InvalidStartTime();

        Grant storage currentGrant = grants[recipient];

        // Only allow creating new grants, not updating existing ones
        if (currentGrant.totalAmount != 0) revert RecipientAlreadyHasGrant();

        // Check allowance before attempting transfer (better UX)
        uint256 allowance = IERC20(GRANT_TOKEN).allowance(msg.sender, address(this));
        if (allowance < totalAmount) revert InsufficientAllowance();

        // Set grant parameters with safe casting
        currentGrant.totalAmount = MathUtils.safe128(totalAmount);
        currentGrant.claimedAmount = 0;
        currentGrant.startTime = startTime;
        currentGrant.duration = duration;
        currentGrant.cliffDuration = cliffDuration;
        currentGrant.isActive = true;

        // Transfer tokens from owner to vault for grant funding
        // Production: Consider using external vault pattern for better fund isolation
        // Production: Use TransferHelper.safeTransferFrom for better error handling
        IERC20(GRANT_TOKEN).transferFrom(msg.sender, address(this), totalAmount);

        emit GrantCreated(recipient, totalAmount, startTime, duration, cliffDuration);
    }

    /**
     * @notice Owner updates an existing active grant for a recipient.
     * @dev MVP: Only allows increasing grant amount and adjusting timing within safe bounds.
     * @dev For amount increases, owner must approve additional tokens first.
     * @param recipient Address of the grant recipient
     * @param newTotalAmount New total amount (must be >= current total)
     * @param newDuration New duration (must be >= current to prevent acceleration)
     * @param newCliffDuration New cliff duration (must be <= current for fairness)
     */
    function updateGrant(
        address recipient,
        uint256 newTotalAmount,
        uint32 newDuration,
        uint32 newCliffDuration
    ) external onlyOwner {
        // Input validation
        if (recipient == address(0)) revert ZeroAddress();
        if (newCliffDuration > newDuration) revert InvalidCliffDuration();
        
        Grant storage currentGrant = grants[recipient];

        // Grant must exist and be active
        if (currentGrant.totalAmount == 0) {
            // Check if grant ever existed by looking at other fields
            if (currentGrant.startTime > 0 || currentGrant.duration > 0) revert GrantInactive();
            else revert GrantNotFound();
        }
        if (!currentGrant.isActive) revert GrantInactive();

        // Safety checks for updates to protect recipient
        
        // 1. Can only increase total amount (prevents rugging)
        if (newTotalAmount < currentGrant.totalAmount) {
            revert InvalidAmount();
        }

        // 2. Can only increase or maintain duration (prevents vesting acceleration)
        // Decreasing duration would make tokens vest faster, which could be exploited
        if (newDuration < currentGrant.duration) {
            revert InvalidDuration();
        }

        // 3. Can only decrease or maintain cliff (prevents delaying access)
        // Increasing cliff would lock vested tokens, harming recipient
        if (newCliffDuration > currentGrant.cliffDuration) {
            revert InvalidCliffDuration();
        }

        uint256 additionalAmount = newTotalAmount - currentGrant.totalAmount;

        // If increasing amount, check allowance
        if (additionalAmount > 0) {
            uint256 allowance = IERC20(GRANT_TOKEN).allowance(msg.sender, address(this));
            if (allowance < additionalAmount) revert InsufficientAllowance();
        }

        // Update grant parameters
        currentGrant.totalAmount = MathUtils.safe128(newTotalAmount);
        currentGrant.duration = newDuration;
        currentGrant.cliffDuration = newCliffDuration;

        // Transfer additional tokens if needed
        if (additionalAmount > 0) {
            // Production: Use TransferHelper.safeTransferFrom for better error handling
            IERC20(GRANT_TOKEN).transferFrom(msg.sender, address(this), additionalAmount);
        }

        emit GrantUpdated(
            recipient, 
            newTotalAmount, 
            additionalAmount, 
            newDuration, 
            newCliffDuration
        );
    }

    /**
     * @notice Recipient claims all available vested funds.
     * @dev Applies protocol fee and transfers net amount to recipient.
     * @dev Uses reentrancy guard and pause check for security.
     */
    function claim() external onlyWhenNotPaused nonReentrant {
        Grant storage grant = grants[msg.sender];
        if (grant.totalAmount == 0) revert GrantNotFound();

        // Calculate available funds to claim
        (, uint256 availableToClaim) = _calculateVestedAndAvailable(grant, msg.sender);
        if (availableToClaim == 0) revert NoVestedFunds();

        // Calculate protocol fee and net amount
        (uint256 feeAmount, uint256 netAmount) = _calculateFeeAndNetAmount(availableToClaim);

        // Update state BEFORE external calls (CEI pattern)
        grant.claimedAmount = MathUtils.safe128(grant.claimedAmount + availableToClaim);

        // Execute transfers
        if (feeAmount > 0) {
            // Production: Use TransferHelper.safeTransfer for better error handling
            IERC20(GRANT_TOKEN).transfer(FEE_RECIPIENT, feeAmount);
        }
        
        if (netAmount > 0) {
            // Production: Use TransferHelper.safeTransfer for better error handling
            IERC20(GRANT_TOKEN).transfer(msg.sender, netAmount);
        }

        emit FundsClaimed(msg.sender, availableToClaim, feeAmount, netAmount);
    }

    // --- Admin Functions ---

    /**
     * @notice Owner can pause/unpause all claims for emergency situations.
     * @param newPausedState True to pause claims, false to resume
     */
    function togglePause(bool newPausedState) external onlyOwner {
        paused = newPausedState;
        emit ClaimsPausedToggled(msg.sender, newPausedState);
    }

    /**
     * @notice Owner revokes an active grant and returns unvested funds.
     * @dev Recipient keeps any already-vested but unclaimed funds.
     * @dev Grant is marked inactive and totalAmount is locked to vested amount.
     * @param recipient Address of the grant recipient to revoke
     * 
     * Future Enhancement - Add reactivateGrant function to restore revoked grants
     * This would allow owners to reactivate grants that were revoked, useful for:
     * - Temporary suspensions that need to be lifted
     * - Administrative corrections
     * - Grant modifications that require revocation and recreation
     */
    function revokeGrant(address recipient) external onlyOwner {
        Grant storage grant = grants[recipient];
        
        if (grant.totalAmount == 0) {
            // Check if grant ever existed by looking at other fields
            if (grant.startTime > 0 || grant.duration > 0) revert GrantInactive();
            else revert GrantNotFound();
        }
        if (!grant.isActive) revert GrantInactive(); // Already revoked

        uint256 totalVested = vestedAmount(recipient);
        uint256 unvestedAmount = uint256(grant.totalAmount) - totalVested;
        
        // --- State Update: Lock the claimable funds ---
        
        // 1. Mark as inactive (stops further vesting calculation)
        grant.isActive = false;

        uint256 vestedUnclaimed = totalVested - uint256(grant.claimedAmount);
        
        // 2. Lock totalAmount to the vested unclaimed amount at revocation time
        // This ensures recipient can only claim what was vested but not yet claimed
        grant.totalAmount = MathUtils.safe128(vestedUnclaimed);
        grant.claimedAmount = 0; // Reset claimed amount since totalAmount now represents claimable amount
    

        // 3. Return unvested funds to current owner
        if (unvestedAmount > 0) {
            // Production: Use TransferHelper.safeTransfer for better error handling
            IERC20(GRANT_TOKEN).transfer(owner, unvestedAmount);
        }

        emit GrantRevoked(recipient, vestedUnclaimed, unvestedAmount);
    }

    // Future Enhancement - Add recoverTokens function for emergency token recovery
    // This would allow owners to recover tokens sent to the contract by mistake
    // Should include proper accounting to distinguish between grant funds and accidental transfers

    // --- Upgrade Path Notes ---
    /**
     * Production Upgrade Path: UUPS Proxy Pattern
     * 
     * 1. Inherit from UUPSUpgradeable and Initializable (OpenZeppelin)
     * 2. Replace constructor with initialize() function
     * 3. Add storage gap: uint256[50] private __gap;
     * 4. Implement _authorizeUpgrade():
     *    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
     * 5. Use OpenZeppelin's upgradeable contract variants
     * 6. Deploy with ERC1967Proxy pointing to implementation
     * 7. Test storage layout compatibility before each upgrade
     * 
     * Security Considerations:
     * - Always use storage gaps to allow future variable additions
     * - Never change order of existing state variables
     * - Test thoroughly with OpenZeppelin Upgrades plugin
     * - Consider using TransparentUpgradeableProxy for simpler upgrade control
     * - Implement timelocks on upgrades for user safety
     */
}