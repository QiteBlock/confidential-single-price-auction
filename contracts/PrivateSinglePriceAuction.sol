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
    uint256 public maxParticipant;

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

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }

    modifier activeAuction() {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Auction is not active");
        _;
    }

    modifier auctionEnded() {
        require(block.timestamp > endTime, "Auction is still active");
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

    /// @notice Public function to place a bid
    /// @param encryptedQuantity Encrypted quantity of tokens bid
    /// @param encryptedPrice Encrypted price per token bid
    function placeBid(euint256 encryptedQuantity, euint256 encryptedPrice) public payable activeAuction {
        uint256 length = bids.length;
        require(!hasParticipated[msg.sender], "Already placed a bid");
        require(length <= maxParticipant, "Max participant reached");
        // Calculate total bid amount in payment token's precision
        euint256 totalBids = TFHE.mul(encryptedPrice, encryptedQuantity);
        uint decimals = paymentToken == address(0) ? 18 : ERC20(paymentToken).decimals();
        euint256 totalBidsSamePrecision = TFHE.div(totalBids, 10 ** decimals);

        // Verify if the user has locked sufficient funds
        ebool isLockFundsGreater = TFHE.ge(TFHE.asEuint256(lockedFunds[msg.sender]), totalBidsSamePrecision);
        if (paymentToken == address(0)) {
            isLockFundsGreater = TFHE.and(
                TFHE.eq(totalBidsSamePrecision, TFHE.asEuint256(msg.value)),
                isLockFundsGreater
            );
        }

        // Store final bid values based on sufficient funds
        euint256 finalEncryptedQuantity = TFHE.select(isLockFundsGreater, encryptedQuantity, TFHE.asEuint256(0));
        euint256 finalEncryptedPrice = TFHE.select(isLockFundsGreater, encryptedPrice, TFHE.asEuint256(0));

        // Record the bid
        bids.push(
            EncryptedBid({
                bidder: msg.sender,
                encryptedQuantity: finalEncryptedQuantity,
                encryptedPrice: finalEncryptedPrice
            })
        );
        hasParticipated[msg.sender] = true;

        // Approve TFHE for decryption
        TFHE.allowThis(bids[length].encryptedQuantity);
        TFHE.allowThis(bids[length].encryptedPrice);
        TFHE.allow(bids[length].encryptedQuantity, msg.sender);
        TFHE.allow(bids[length].encryptedPrice, msg.sender);

        emit EncryptedBidPlaced(msg.sender, finalEncryptedQuantity, finalEncryptedPrice);
    }

    function distributeFunds() internal nonReentrant {
        uint256 totalAmountPaid = 0;
        uint256 remainingQuantity = quantity;

        DecryptedBid[] memory sortedBids = sortBidsByPriceDescending();
        DecryptedBid[] memory winners = allocateWinners(sortedBids, remainingQuantity);

        totalAmountPaid = processPayments(winners);
        transferFundsToOwner(totalAmountPaid);
        distributeAssetsToWinners(winners);
        refundLockedFunds();
        refundUnsoldAssets();
    }

    function sortBidsByPriceDescending() private view returns (DecryptedBid[] memory) {
        uint256 n = decryptedBids.length;
        DecryptedBid[] memory sortedBids = new DecryptedBid[](n);

        // Reorder decryptedBids to match the order in bids
        for (uint256 i = 0; i < n; i++) {
            // Find the corresponding decrypted bid for the current encrypted bid
            for (uint256 j = 0; j < n; j++) {
                if (decryptedBids[j].bidder == bids[i].bidder) {
                    sortedBids[i] = decryptedBids[j];
                    break;
                }
            }
        }

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
            remainingQuantity -= allocatedQuantity;
            if (remainingQuantity == 0 || i == n - 1) {
                settlementPrice = winners[i].price;
            }
        }
        return winners;
    }

    function processPayments(DecryptedBid[] memory winners) private returns (uint256 totalAmountPaid) {
        uint256 decimals = paymentToken == address(0) ? 18 : ERC20(paymentToken).decimals();

        for (uint256 i = 0; i < winners.length; i++) {
            if (winners[i].bidder != address(0)) {
                uint256 payableAmount = (winners[i].quantity * settlementPrice) / 10 ** decimals;
                lockedFunds[winners[i].bidder] -= payableAmount;
                totalAmountPaid += payableAmount;
            }
        }
    }

    function transferFundsToOwner(uint256 totalAmountPaid) private {
        if (paymentToken == address(0)) {
            (bool success, ) = owner.call{ value: totalAmountPaid }("");
            require(success, "Transfer to owner failed");
        } else {
            require(ERC20(paymentToken).transfer(owner, totalAmountPaid), "Transfer to owner failed");
        }
    }

    function distributeAssetsToWinners(DecryptedBid[] memory winners) private {
        for (uint256 i = 0; i < winners.length; i++) {
            if (winners[i].bidder != address(0)) {
                require(ERC20(asset).transfer(winners[i].bidder, winners[i].quantity), "Distribute assets failed");
            }
        }
    }

    function refundLockedFunds() private {
        for (uint256 i = 0; i < lockedParticipant.length; i++) {
            address participant = lockedParticipant[i];
            uint256 refundAmount = lockedFunds[participant];
            if (refundAmount > 0) {
                if (paymentToken == address(0)) {
                    (bool success, ) = participant.call{ value: refundAmount }("");
                    require(success, "Ether refund failed");
                } else {
                    require(ERC20(paymentToken).transfer(participant, refundAmount), "Token refund failed");
                }
            }
        }
    }

    function refundUnsoldAssets() private {
        uint256 unsoldAssets = ERC20(asset).balanceOf(address(this));
        if (unsoldAssets > 0) {
            require(ERC20(asset).transfer(owner, unsoldAssets), "Refund unsold assets failed");
        }
    }

    /// @notice Finalize the auction and distribute tokens
    function settleAuction() public onlyOwner auctionEnded {
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
            block.timestamp + 100,
            false
        );
        requestIds.push(requestID);
        addParamsAddress(requestID, _bidder);
    }

    /// @notice Callback function to handle decrypted bid data
    function callbackDecrypted(uint256 requestId, uint256 _quantity, uint256 _price) public onlyGateway {
        address[] memory params = getParamsAddress(requestId);
        decryptedBids.push(DecryptedBid(params[0], _quantity, _price));
        isDecrypted[requestId] = true;
        if (checkAllDecrypted()) {
            distributeFunds();
        }
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
        // Ensure that the user sends enough funds for locking
        require(amount > 0, "Amount must be greater than zero");

        // Lock Ether
        if (paymentToken == address(0)) {
            require(msg.value == amount, "Ether amount mismatch");
            lockedFunds[msg.sender] += msg.value;
        }
        // Lock ERC20 tokens
        else {
            require(ERC20(paymentToken).transferFrom(msg.sender, address(this), amount), "ERC20 transfer failed");
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
