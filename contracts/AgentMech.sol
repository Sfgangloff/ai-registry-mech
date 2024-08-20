// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC721Mech} from "../lib/gnosis-mech/contracts/ERC721Mech.sol";

// Mech delivery info struct
struct MechDelivery {
    // Priority mech address
    address priorityMech;
    // Delivery mech address
    address deliveryMech;
    // Account address sending the request
    address account;
    // Response timeout window
    uint32 responseTimeout;
}

// Mech Marketplace interface
interface IMechMarketplace {
    /// @dev Delivers a request.
    /// @param requestId Request id.
    /// @param requestIdWithNonce Request id with nonce.
    /// @param requestData Self-descriptive opaque data-blob.
    function deliver(uint256 requestId, uint256 requestIdWithNonce, bytes memory requestData) external;

    /// @dev Gets mech delivery info.
    /// @param requestIdWithNonce Request Id with nonce.
    /// @return Mech delivery info.
    function getMechDeliveryInfo(uint256 requestIdWithNonce) external returns (MechDelivery memory);
}

// Token interface
interface IToken {
    /// @dev Gets the owner of the `tokenId` token.
    /// @param tokenId Token Id that must exist.
    /// @return tokenOwner Token owner.
    function ownerOf(uint256 tokenId) external view returns (address tokenOwner);
}

/// @dev Provided zero address.
error ZeroAddress();

/// @dev Only `manager` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param manager Required sender address as a manager.
error ManagerOnly(address sender, address manager);

/// @dev Agent does not exist.
/// @param agentId Agent Id.
error AgentNotFound(uint256 agentId);

/// @dev Not enough value paid.
/// @param provided Provided amount.
/// @param expected Expected amount.
error NotEnoughPaid(uint256 provided, uint256 expected);

/// @dev Request Id not found.
/// @param requestId Request Id.
error RequestIdNotFound(uint256 requestId);

/// @dev Value overflow.
/// @param provided Overflow value.
/// @param max Maximum possible value.
error Overflow(uint256 provided, uint256 max);

/// @dev Caught reentrancy violation.
error ReentrancyGuard();

/// @title AgentMech - Smart contract for extending ERC721Mech
/// @dev A Mech that is operated by the holder of an ERC721 non-fungible token.
contract AgentMech is ERC721Mech {
    event Deliver(address indexed sender, uint256 requestId, uint256 requestIdWithNonce, bytes data);
    event Request(address indexed sender, uint256 requestId, uint256 requestIdWithNonce, bytes data);
    event RevokeRequest(address indexed sender, uint256 requestIdWithNonce);
    event PriceUpdated(uint256 price);

    // Agent mech version number
    string public constant VERSION = "1.1.0";

    // Minimum required price
    uint256 public price;
    // Number of undelivered requests
    uint256 public numUndeliveredRequests;
    // Number of total requests
    uint256 public numTotalRequests;
    // Mech marketplace address
    address public mechMarketplace;
    // Reentrancy lock
    uint256 internal _locked = 1;

    // Map of requests counts for corresponding addresses
    mapping(address => uint256) public mapRequestsCounts;
    // Map of undelivered requests counts for corresponding addresses
    mapping(address => uint256) public mapUndeliveredRequestsCounts;
    // Cyclical map of request Ids
    mapping(uint256 => uint256[2]) public mapRequestIds;
    // Map of request Id => sender address
    mapping(uint256 => address) public mapRequestAddresses;

    /// @dev AgentMech constructor.
    /// @param _token Address of the token contract.
    /// @param _tokenId The token ID.
    /// @param _price The minimum required price.
    constructor(address _mechMarketplace, address _token, uint256 _tokenId, uint256 _price) ERC721Mech(_token, _tokenId) {
        // Check for zero addresses
        if (_mechMarketplace == address(0) || _token == address(0)) {
            revert ZeroAddress();
        }

        // Check for the token to have the owner
        address tokenOwner = IToken(_token).ownerOf(_tokenId);
        if (tokenOwner == address(0)) {
            revert AgentNotFound(_tokenId);
        }

        // Record the mech marketplace
        mechMarketplace = _mechMarketplace;
        // Record the price
        price = _price;
    }

    /// @dev Performs actions before the request is posted.
    /// @param amount Amount of payment in wei.
    function _preRequest(uint256 amount, uint256, bytes memory) internal virtual {
        // Check the request payment
        if (amount < price) {
            revert NotEnoughPaid(amount, price);
        }
    }

    /// @dev Performs actions before the delivery of a request.
    /// @param data Self-descriptive opaque data-blob.
    /// @return requestData Data for the request processing.
    function _preDeliver(address, uint256, bytes memory data) internal virtual returns (bytes memory requestData) {
        requestData = data;
    }

    /// @dev Cleans the request info from all the relevant storage.
    /// @param account Requester account address.
    /// @param requestIdWithNonce Request Id with nonce.
    function _cleanRequestInfo(address account, uint256 requestIdWithNonce) internal {
        // Decrease the number of undelivered requests
        mapUndeliveredRequestsCounts[account]--;
        numUndeliveredRequests--;

        // Remove delivered request Id from the request Ids map
        uint256[2] memory requestIds = mapRequestIds[requestIdWithNonce];
        // Check if the request Id is invalid (non existent or delivered): previous and next request Ids are zero,
        // and the zero's element previous request Id is not equal to the provided request Id
        if (requestIds[0] == 0 && requestIds[1] == 0 && mapRequestIds[0][0] != requestIdWithNonce) {
            revert RequestIdNotFound(requestIdWithNonce);
        }

        // Re-link previous and next elements between themselves
        mapRequestIds[requestIds[0]][1] = requestIds[1];
        mapRequestIds[requestIds[1]][0] = requestIds[0];

        // Delete the delivered element from the map
        delete mapRequestIds[requestIdWithNonce];
        delete mapRequestAddresses[requestIdWithNonce];
    }

    /// @dev Changes mech marketplace address.
    /// @param newMechMarketplace New mech marketplace address.
    function changeMechMarketplace(address newMechMarketplace) external onlyOperator {
        // Check for zero address
        if (newMechMarketplace == address(0)) {
            revert ZeroAddress();
        }

        mechMarketplace = newMechMarketplace;
    }

    /// @dev Registers a request.
    /// @notice This function is called by the marketplace contract since this mech was specified as a priority one.
    /// @param account Requester account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param requestId Request Id.
    /// @param requestIdWithNonce Request Id with nonce.
    function request(
        address account,
        bytes memory data,
        uint256 requestId,
        uint256 requestIdWithNonce
    ) external payable {
        if (msg.sender != mechMarketplace) {
            revert ManagerOnly(msg.sender, mechMarketplace);
        }

        // Check the request payment
        _preRequest(msg.value, requestIdWithNonce, data);

        // Increase the requests count supplied by the sender
        mapRequestsCounts[account]++;
        mapUndeliveredRequestsCounts[account]++;
        // Record the requestIdWithNonce => sender correspondence
        mapRequestAddresses[requestIdWithNonce] = account;

        // Record the request Id in the map
        // Get previous and next request Ids of the first element
        uint256[2] storage requestIds = mapRequestIds[0];
        // Create the new element
        uint256[2] storage newRequestIds = mapRequestIds[requestIdWithNonce];

        // Previous element will be zero, next element will be the current next element
        uint256 curNextRequestId = requestIds[1];
        newRequestIds[1] = curNextRequestId;
        // Next element of the zero element will be the newly created element
        requestIds[1] = requestIdWithNonce;
        // Previous element of the current next element will be the newly created element
        mapRequestIds[curNextRequestId][0] = requestIdWithNonce;

        // Increase the number of undelivered requests
        numUndeliveredRequests++;
        // Increase the total number of requests
        numTotalRequests++;

        emit Request(account, requestId, requestIdWithNonce, data);
    }

    /// @dev Revokes the request from the mech that does not deliver it.
    /// @notice Only marketplace can call this function if the request is not delivered by the chosen priority mech.
    /// @param requestIdWithNonce Request Id with nonce.
    function revokeRequest(uint256 requestIdWithNonce) external {
        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert ManagerOnly(msg.sender, mechMarketplace);
        }

        address account = mapRequestAddresses[requestIdWithNonce];
        // This must never happen, as the priority mech recorded requestIdWithNonce => account info during the request
        if (account == address(0)) {
            revert ZeroAddress();
        }
        // Decrease the total number of requests by this mech
        mapRequestsCounts[account]--;
        numTotalRequests--;

        // Clean request info
        _cleanRequestInfo(account, requestIdWithNonce);

        emit RevokeRequest(account, requestIdWithNonce);
    }

    /// @dev Delivers a request.
    /// @notice This function ultimately calls mech marketplace contract to finalize the delivery.
    /// @param requestId Request id.
    /// @param requestIdWithNonce Request id with nonce.
    /// @param data Self-descriptive opaque data-blob.
    function deliver(uint256 requestId, uint256 requestIdWithNonce, bytes memory data) external onlyOperator {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Get the account to deliver request to
        address account = mapRequestAddresses[requestIdWithNonce];
        // The account is zero if the delivery mech is different from a priority mech
        if (account == address(0)) {
            account = IMechMarketplace(mechMarketplace).getMechDeliveryInfo(requestIdWithNonce).account;

            // This must never happen, as each valid requestIdWithNonce has a corresponding account recorded in marketplace
            if (account == address(0)) {
                revert ZeroAddress();
            }

            // Increase the total number of requests, as the request is delivered by this mech
            mapRequestsCounts[account]++;
            numTotalRequests++;
        } else {
            // The account is non-zero if it is delivered by the priority mech
            _cleanRequestInfo(account, requestIdWithNonce);
        }

        // Perform a pre-delivery of the data if it needs additional parsing
        bytes memory requestData = _preDeliver(account, requestIdWithNonce, data);

        // Mech marketplace delivery finalization
        IMechMarketplace(mechMarketplace).deliver(requestId, requestIdWithNonce, requestData);

        emit Deliver(msg.sender, requestId, requestIdWithNonce, requestData);

        _locked = 1;
    }

    /// @dev Sets the new price.
    /// @param newPrice New mimimum required price.
    function setPrice(uint256 newPrice) external onlyOperator {
        price = newPrice;
        emit PriceUpdated(newPrice);
    }

    /// @dev Gets the requests count for a specific account.
    /// @param account Account address.
    /// @return requestsCount Requests count.
    function getRequestsCount(address account) external view returns (uint256 requestsCount) {
        requestsCount = mapRequestsCounts[account];
    }

    /// @dev Gets the set of undelivered request Ids with Nonce.
    /// @param size Maximum batch size of a returned requests Id set. If the size is zero, the whole set is returned.
    /// @param offset The number of skipped requests that are not going to be part of the returned requests Id set.
    /// @return requestIds Set of undelivered request Ids.
    function getUndeliveredRequestIds(uint256 size, uint256 offset) external view returns (uint256[] memory requestIds) {
        // Get the number of undelivered requests
        uint256 numRequests = numUndeliveredRequests;

        // If size is zero, return all the requests
        if (size == 0) {
            size = numRequests;
        }

        // Check for the size + offset overflow
        if (size + offset > numRequests) {
            revert Overflow(size + offset, numRequests);
        }

        if (size > 0) {
            requestIds = new uint256[](size);

            // The first request Id is the next request Id of the zero element in the request Ids map
            uint256 curRequestId = mapRequestIds[0][1];
            // Traverse requests a specified offset
            for (uint256 i = 0; i < offset; ++i) {
                // Next request Id of the current element based on the current request Id
                curRequestId = mapRequestIds[curRequestId][1];
            }

            // Traverse the rest of requests
            for (uint256 i = 0; i < size; ++i) {
                requestIds[i] = curRequestId;
                // Next request Id of the current element based on the current request Id
                curRequestId = mapRequestIds[curRequestId][1];
            }
        }
    }
}
