// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "fhevm/lib/TFHE.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
import "fhevm/config/ZamaGatewayConfig.sol";
import "fhevm/gateway/GatewayCaller.sol";

contract PrivateSinglePriceAuction is SepoliaZamaFHEVMConfig, SepoliaZamaGatewayConfig, GatewayCaller, ReentrancyGuard {
    address public owner; // Owner of the auction contract
    address public asset; // Address of the ERC20 token being auctioned
    address public paymentToken; // Address of the payment token (0 for Ether)
    uint256 public quantity; // Total quantity of tokens being auctioned
    uint256 public startTime; // Start time of the auction
    uint256 public endTime; // End time of the auction
    uint256 public maxParticipant; // Maximum number of participants

    struct EncryptedBid {
        address bidder;
        euint256 encryptedQuantity; // Encrypted quantity of tokens bid
        euint256 encryptedPrice; // Encrypted price per token
    }

    struct DecryptedBid {
        address bidder;
        uint256 quantity; // Decrypted quantity of tokens bid
        uint256 price; // Decrypted price per token
    }

    EncryptedBid[] public bids; // List of all encrypted bids
    DecryptedBid[] public decryptedBids; // List of all decrypted bids
    uint256[] public requestIds; // List of request IDs for decryption
    uint256 public settlementPrice = 0; // Final settlement price
    mapping(uint256 => bool) public isDecrypted; // Tracks decryption status of bids
    mapping(address => bool) public hasParticipated; // Tracks if a user has placed a bid
    address[] public lockedParticipant; // List of participants with locked funds
    mapping(address => uint256) public lockedFunds; // Tracks locked funds for each participant
    bool public settled; // Indicates whether the auction is settled

    event AuctionCreated(address indexed asset, address indexed paymentToken, uint256 quantity);
    event EncryptedBidPlaced(address indexed bidder, euint256 quantity, euint256 price);
    event AuctionSettled(euint256 settlementPrice);
    event DecryptionRequested(uint256 indexed requestId, address indexed bidder);
    event DecryptionCompleted(uint256 indexed requestId, address indexed bidder, uint256 quantity, uint256 price);

    // Custom errors for gas-efficient error handling
    error AuctionNotActive(); // Thrown when auction is not in active state
    error AuctionStillActive(); // Thrown when auction hasn't ended yet
    error NotOwner(); // Thrown when caller is not the auction owner
    error AuctionAlreadySettled(); // Thrown when trying to settle an already settled auction
    error ZeroAmount(); // Thrown when attempting to lock zero funds
    error EtherAmountMismatch(); // Thrown when sent ETH doesn't match specified amount
    error ERC20TransferFailed(); // Thrown when ERC20 token transfer fails
    error AlreadyDecrypted(); // Thrown when bid is already decrypted
    error InvalidParams(); // Thrown when decryption parameters are invalid
    error TransferToOwnerFailed(); // Thrown when transfer to owner fails
    error DistributeAssetsFailed(); // Thrown when asset distribution fails
    error EtherRefundFailed(); // Thrown when ETH refund fails
    error RefundAssetsFailed(); // Thrown when asset refund fails
    error NotAllDecrypted(); // Thrown when not all bids are decrypted
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier activeAuction() {
        if (block.timestamp < startTime || block.timestamp > endTime) revert AuctionNotActive();
        _;
    }

    modifier auctionEnded() {
        if (block.timestamp <= endTime) revert AuctionStillActive();
        _;
    }

    /// @notice Constructor to initialize the auction
    constructor(
        address _owner,
        address _asset,
        address _paymentToken,
        uint256 _quantity,
        uint256 _duration,
        uint256 _maxParticipant
    ) {
        owner = _owner;
        asset = _asset;
        paymentToken = _paymentToken;
        quantity = _quantity;
        startTime = block.timestamp;
        endTime = startTime + _duration;
        maxParticipant = _maxParticipant;

        emit AuctionCreated(_asset, _paymentToken, _quantity);
    }

    /// @notice Place an encrypted bid in the auction
    /// @param _encryptedQuantity Encrypted quantity of tokens bid
    /// @param _encryptedPrice Encrypted price per token bid
    /// @param _inputProof Proof for encryption
    /// @return Returns true if the bid is placed successfully
    function placeEncryptedBid(
        einput _encryptedQuantity,
        einput _encryptedPrice,
        bytes calldata _inputProof
    ) external payable returns (bool) {
        placeBid(TFHE.asEuint256(_encryptedQuantity, _inputProof), TFHE.asEuint256(_encryptedPrice, _inputProof));
        return true;
    }

    /// @notice Places an encrypted bid with verification
    /// @param encryptedQuantity The encrypted amount of tokens to bid for
    /// @param encryptedPrice The encrypted price per token
    function placeBid(euint256 encryptedQuantity, euint256 encryptedPrice) public payable activeAuction {
        uint256 length = bids.length;
        require(!hasParticipated[msg.sender] && length <= maxParticipant, "Invalid bid");

        // Convert bid to payment token precision and verify sufficient locked funds
        euint256 totalBids = TFHE.mul(encryptedPrice, encryptedQuantity);
        uint256 decimals = paymentToken == address(0) ? 18 : ERC20(paymentToken).decimals();
        euint256 totalBidsSamePrecision = TFHE.div(totalBids, 10 ** decimals);

        // Check if user has locked enough funds (in encrypted space)
        ebool isLockFundsGreater = TFHE.ge(TFHE.asEuint256(lockedFunds[msg.sender]), totalBidsSamePrecision);

        // If insufficient funds, bid quantities are set to 0 while maintaining privacy
        euint256 finalEncryptedQuantity = TFHE.select(isLockFundsGreater, encryptedQuantity, TFHE.asEuint256(0));
        euint256 finalEncryptedPrice = TFHE.select(isLockFundsGreater, encryptedPrice, TFHE.asEuint256(0));

        // Store the bid
        EncryptedBid storage newBid = bids.push();
        newBid.bidder = msg.sender;
        newBid.encryptedQuantity = finalEncryptedQuantity;
        newBid.encryptedPrice = finalEncryptedPrice;

        hasParticipated[msg.sender] = true;

        // Grant necessary TFHE permissions for later decryption
        TFHE.allowThis(bids[length].encryptedQuantity);
        TFHE.allowThis(bids[length].encryptedPrice);
        TFHE.allow(bids[length].encryptedQuantity, msg.sender);
        TFHE.allow(bids[length].encryptedPrice, msg.sender);

        emit EncryptedBidPlaced(msg.sender, finalEncryptedQuantity, finalEncryptedPrice);
    }

    /// @notice Distributes funds and assets after auction settlement
    /// @dev Processes winner payments, transfers assets, and handles refunds
    function distributeFunds() internal nonReentrant {
        uint256 totalAmountPaid;
        uint256 decimals = paymentToken == address(0) ? 18 : ERC20(paymentToken).decimals();

        // Sort bids and determine winners
        DecryptedBid[] memory winners = allocateWinners(sortBidsByPriceDescending(), quantity);

        // Process payments and distribute assets to winners
        for (uint256 i = 0; i < winners.length; i++) {
            address bidder = winners[i].bidder;
            if (bidder != address(0)) {
                uint256 payableAmount = (winners[i].quantity * settlementPrice) / 10 ** decimals;
                lockedFunds[bidder] -= payableAmount;
                totalAmountPaid += payableAmount;

                if (!ERC20(asset).transfer(bidder, winners[i].quantity)) revert DistributeAssetsFailed();
            }
        }

        // Transfer collected funds to auction owner
        if (paymentToken == address(0)) {
            (bool success, ) = owner.call{ value: totalAmountPaid }("");
            if (!success) revert TransferToOwnerFailed();
        } else {
            if (!ERC20(paymentToken).transfer(owner, totalAmountPaid)) revert TransferToOwnerFailed();
        }

        _processRefunds();
    }

    /// @notice Processes refunds for unused locked funds and unsold assets
    /// @dev Returns excess funds to participants and unsold assets to owner
    function _processRefunds() private {
        // Refund excess locked funds to participants
        for (uint256 i = 0; i < lockedParticipant.length; i++) {
            address participant = lockedParticipant[i];
            uint256 refundAmount = lockedFunds[participant];
            if (refundAmount > 0) {
                lockedFunds[participant] = 0;
                if (paymentToken == address(0)) {
                    (bool success, ) = participant.call{ value: refundAmount }("");
                    if (!success) revert EtherRefundFailed();
                } else {
                    if (!ERC20(paymentToken).transfer(participant, refundAmount)) revert ERC20TransferFailed();
                }
            }
        }

        // Return any unsold assets to the auction owner
        uint256 unsoldAssets = ERC20(asset).balanceOf(address(this));
        if (unsoldAssets > 0) {
            if (!ERC20(asset).transfer(owner, unsoldAssets)) revert RefundAssetsFailed();
        }
    }

    /// @notice Sorts decrypted bids by price in descending order
    /// @dev Maintains bid order consistency with original encrypted bids
    /// @return Sorted array of DecryptedBid structs
    function sortBidsByPriceDescending() private view returns (DecryptedBid[] memory) {
        uint256 n = decryptedBids.length;
        DecryptedBid[] memory sortedBids = new DecryptedBid[](n);

        // First match decrypted bids with their original encrypted order
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                if (decryptedBids[j].bidder == bids[i].bidder) {
                    sortedBids[i] = decryptedBids[j];
                    break;
                }
            }
        }

        // Sort by price using bubble sort
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (sortedBids[j].price < sortedBids[j + 1].price) {
                    DecryptedBid memory temp = sortedBids[j];
                    sortedBids[j] = sortedBids[j + 1];
                    sortedBids[j + 1] = temp;
                }
            }
        }
        return sortedBids;
    }

    function allocateWinners(
        DecryptedBid[] memory sortedBids,
        uint256 remainingQuantity
    ) private returns (DecryptedBid[] memory) {
        uint256 n = sortedBids.length;
        DecryptedBid[] memory winners = new DecryptedBid[](n);

        for (uint256 i = 0; i < n; i++) {
            if (remainingQuantity == 0) break;

            uint256 allocatedQuantity = sortedBids[i].quantity;
            if (remainingQuantity < allocatedQuantity) {
                allocatedQuantity = remainingQuantity;
            }

            sortedBids[i].quantity = allocatedQuantity;
            winners[i] = sortedBids[i];

            unchecked {
                remainingQuantity -= allocatedQuantity;
            }

            if (remainingQuantity == 0 || i == n - 1) {
                settlementPrice = winners[i].price;
            }
        }
        return winners;
    }

    /// @notice Finalize the auction and distribute tokens
    function settleAuction() public onlyOwner auctionEnded {
        if (settled) revert AuctionAlreadySettled();
        require(!settled, "Auction already settled");

        // euint256 remainingQuantity = TFHE.asEuint256(quantity);
        euint256 priceOfAuction = TFHE.asEuint256(0);

        // Decrypt bidders data
        for (uint256 i = 0; i < bids.length; i++) {
            requestDecryption(bids[i].encryptedQuantity, bids[i].encryptedPrice, bids[i].bidder);
        }
        settled = true;
        emit AuctionSettled(priceOfAuction);
    }

    /// @notice Request decryption of encrypted bids
    function requestDecryption(euint256 _quantity, euint256 _price, address _bidder) public {
        uint256[] memory cts = new uint256[](2);
        cts[0] = Gateway.toUint256(_quantity);
        cts[1] = Gateway.toUint256(_price);
        uint256 requestID = Gateway.requestDecryption(
            cts,
            this.callbackDecrypted.selector,
            0,
            block.timestamp + 1 hours,
            false
        );
        requestIds.push(requestID);
        addParamsAddress(requestID, _bidder);
        emit DecryptionRequested(requestID, _bidder);
    }

    /// @notice Callback function to handle decrypted bid data
    function callbackDecrypted(uint256 requestId, uint256 _quantity, uint256 _price) public onlyGateway {
        if (isDecrypted[requestId]) revert AlreadyDecrypted();
        address[] memory params = getParamsAddress(requestId);
        if (params.length == 0) revert InvalidParams();
        address bidder = params[0];

        decryptedBids.push(DecryptedBid(bidder, _quantity, _price));
        isDecrypted[requestId] = true;

        emit DecryptionCompleted(requestId, bidder, _quantity, _price);
    }

    function distributeFunds() external onlyOwner auctionEnded {
        if (!checkAllDecrypted()) revert NotAllDecrypted();
        distributeFunds();
    }

    /// @notice Check if all decryption requests are completed
    function checkAllDecrypted() public view returns (bool) {
        // Loop through the array and check the mapping
        for (uint256 i = 0; i < requestIds.length; i++) {
            if (!isDecrypted[requestIds[i]]) {
                return false; // If any value is false, return false
            }
        }
        return true; // All values are true
    }

    /// @notice Lock funds for bidding
    /// @param amount Amount of funds to lock
    function lockFunds(uint256 amount) external payable nonReentrant activeAuction {
        if (amount == 0) revert ZeroAmount();

        if (paymentToken == address(0)) {
            if (msg.value != amount) revert EtherAmountMismatch();
            lockedFunds[msg.sender] += msg.value;
        } else {
            if (!ERC20(paymentToken).transferFrom(msg.sender, address(this), amount)) revert ERC20TransferFailed();
            lockedFunds[msg.sender] += amount;
        }
        lockedParticipant.push(msg.sender);
    }

    /// @notice Get all encrypted bids
    /// @return Array of all encrypted bids
    function getAllBids() public view returns (EncryptedBid[] memory) {
        return bids;
    }

    /// @notice Get all decrypted bids
    /// @return Array of all decrypted bids
    function getAllDecryptedBids() public view returns (DecryptedBid[] memory) {
        return decryptedBids;
    }

    function isActive() public view returns (bool) {
        return block.timestamp >= startTime && block.timestamp <= endTime;
    }
}
