// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract HyperionEngine {
    uint256 private constant MASK_IS_LONG    = 0xFF;
    uint256 private constant MASK_TIMESTAMP  = 0xFFFFFFFFFFFFFF;
    uint256 private constant MASK_PRICE      = 0xFFFFFFFFFFFFFFFF;
    uint256 private constant MASK_SIZE       = 0xFFFFFFFFFFFFFFFF;
    
    uint256 private constant SHIFT_TIMESTAMP = 8;
    uint256 private constant SHIFT_PRICE     = 64;
    uint256 private constant SHIFT_SIZE      = 128;
    uint256 private constant SHIFT_MARGIN    = 192;

    bytes32 private constant REENTRANCY_SLOT = 0x0000000000000000000000000000000000000000000000000000000000000001;
    bytes32 private constant FLASH_DEBT_SLOT = 0x0000000000000000000000000000000000000000000000000000000000000002;

    error SequencerDown();
    error GracePeriodNotMet();
    error StalePrice();
    error ReentrantCall();
    error UnhealthyPosition();
    error FlashAccountingViolation();

    AggregatorV3Interface public immutable i_priceFeed;
    AggregatorV3Interface public immutable i_sequencerFeed;
    uint256 public constant GRACE_PERIOD = 3600;
    
    mapping(address => mapping(uint256 => uint256)) private s_positions;

    modifier nonReentrant() {
        assembly {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, 0x0614e7a2)
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_SLOT, 1)
        }
        _;
        assembly { tstore(REENTRANCY_SLOT, 0) }
    }

    constructor(address priceFeed, address sequencerFeed) {
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_sequencerFeed = AggregatorV3Interface(sequencerFeed);
    }

    function _validateSequencer() internal view {
        (, int256 answer, uint256 startedAt, , ) = i_sequencerFeed.latestRoundData();
        
        if (answer == 1) revert SequencerDown();

        uint256 timeSinceUp = block.timestamp - startedAt;
        if (timeSinceUp < GRACE_PERIOD) revert GracePeriodNotMet();
    }

    function getValidatedPrice() public view returns (uint256) {
        _validateSequencer();

        (, int256 answer, , uint256 updatedAt, ) = i_priceFeed.latestRoundData();
        
        if (updatedAt == 0 || block.timestamp - updatedAt > 2 hours) revert StalePrice();
        if (answer <= 0) revert StalePrice();

        return uint256(answer);
    }

    function openPosition(uint256 marketId, uint256 size, uint256 margin, bool isLong) external nonReentrant {
        uint256 currentPrice = getValidatedPrice();

        assembly {
            let currentDebt := tload(FLASH_DEBT_SLOT)
            tstore(FLASH_DEBT_SLOT, add(currentDebt, margin))
        }

        uint256 packedPosition = (margin << SHIFT_MARGIN) | 
                                 (size << SHIFT_SIZE) | 
                                 (currentPrice << SHIFT_PRICE) | 
                                 (block.timestamp << SHIFT_TIMESTAMP) | 
                                 (isLong ? 1 : 0);

        s_positions[msg.sender][marketId] = packedPosition;

        _checkFlashAccountingRequirements();
    }

    function getPositionDetails(address user, uint256 marketId) 
        external 
        view 
        returns (uint256 margin, uint256 size, uint256 entryPrice, uint256 posTimestamp, bool isLong) 
    {
        uint256 packed = s_positions[user][marketId];
        
        assembly {
            isLong := and(packed, MASK_IS_LONG)
            posTimestamp := and(shr(SHIFT_TIMESTAMP, packed), MASK_TIMESTAMP)
            entryPrice := and(shr(SHIFT_PRICE, packed), MASK_PRICE)
            size := and(shr(SHIFT_SIZE, packed), MASK_SIZE)
            margin := shr(SHIFT_MARGIN, packed)
        }
    }

    function _checkFlashAccountingRequirements() internal view {
        uint256 debt;
        assembly { debt := tload(FLASH_DEBT_SLOT) }
        if (debt > 50000 ether) revert FlashAccountingViolation(); 
    }
}
