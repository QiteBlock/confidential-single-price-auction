// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";

interface IPrivateSinglePriceAuction {
    struct EncryptedBid {
        address bidder;
        euint256 encryptedQuantity;
        euint256 encryptedPrice;
    }

    struct WinnerBid {
        address bidder;
        euint256 encryptedQuantity;
    }

    struct DecryptedBid {
        address bidder;
        uint256 quantity;
    }

    // Public Variables
    function owner() external view returns (address);

    function asset() external view returns (address);

    function paymentToken() external view returns (address);

    function quantity() external view returns (uint256);

    function startTime() external view returns (uint256);

    function endTime() external view returns (uint256);

    function bids(
        uint256 index
    ) external view returns (address bidder, euint256 encryptedQuantity, euint256 encryptedPrice);

    function winnerList(uint256 index) external view returns (address bidder, uint256 quantity);

    function requestIds(uint256 index) external view returns (uint256);

    function settlementPrice() external view returns (uint256);

    function isDecrypted(uint256 requestId) external view returns (bool);

    function hasParticipated(address bidder) external view returns (bool);

    function lockedParticipant(uint256 index) external view returns (address);

    function lockedFunds(address participant) external view returns (uint256);

    function settled() external view returns (bool);

    function active() external view returns (bool);

    // Events
    event AuctionCreated(address indexed asset, address indexed paymentToken, uint256 quantity);
    event EncryptedBidPlaced(address indexed bidder, euint256 quantity, euint256 price);
    event AuctionSettled(euint256 settlementPrice);
    event Withdrawal(address indexed recipient, uint256 amount);

    // Functions
    function placeEncryptedBid(
        einput _encryptedQuantity,
        einput _encryptedPrice,
        bytes calldata _inputProof
    ) external returns (bool);

    function placeBid(euint256 encryptedQuantity, euint256 encryptedPrice) external;

    function lockFunds(uint256 amount) external payable;

    function settleAuction() external;

    function requestDecryption(uint256 nbOfRequests, euint256 nbToDecrypt, address bidder) external;

    function callbackDecrypted(uint256 requestId, uint256 decryptedInput) external returns (uint256);

    function checkAllDecrypted() external view returns (bool);
}
