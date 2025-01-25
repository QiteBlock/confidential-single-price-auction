// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PrivateSinglePriceAuction.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract AuctionFactory {
    address[] public allAuctions;

    event AuctionCreated(
        address auctionAddress,
        address owner,
        address asset,
        address paymentToken,
        uint256 quantity,
        uint256 endTime
    );

    function createAuction(
        address _asset, // ERC20 token being sold
        address _paymentToken, // Ether (address(0)) or ERC20 token used for payment
        uint256 _quantity,
        uint256 _duration,
        uint256 _maxParticipant
    ) external {
        require(_quantity > 0, "Quantity must be greater than zero");
        require(_duration > 0, "Duration must be positive");

        if (_paymentToken != address(0)) {
            require(
                ERC20(_asset).decimals() == ERC20(_paymentToken).decimals(),
                "Asset and payment token must have the same decimals"
            );
        }

        PrivateSinglePriceAuction auction = new PrivateSinglePriceAuction(
            msg.sender,
            _asset,
            _paymentToken,
            _quantity,
            _duration,
            _maxParticipant
        );
        // Transfer the quantity of asset (ERC20 token) into the contract
        allAuctions.push(address(auction));

        require(IERC20(_asset).transferFrom(msg.sender, address(auction), _quantity), "Asset transfer failed");
        emit AuctionCreated(address(auction), msg.sender, _asset, _paymentToken, _quantity, _duration);
    }

    function getAllAuctions() external view returns (address[] memory) {
        return allAuctions;
    }
}
