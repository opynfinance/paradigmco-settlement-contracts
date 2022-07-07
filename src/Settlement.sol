// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.13;

// interface
import {IERC20Metadata as IERC20} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
// contract
// import {EIP712} from "@openzeppelin/utils/cryptography/draft-EIP712.sol";
// lib
import {Counters} from "@openzeppelin/utils/Counters.sol";
import {ECDSA} from "@openzeppelin/utils/cryptography/ECDSA.sol";

/// @title Settlement
/// @author Haythem Sellami
contract Settlement {
    using Counters for Counters.Counter;

    uint256 internal constant MAX_ERROR_COUNT = 7;
    bytes32 public constant DOMAIN_NAME = keccak256("OPYN BRIDGE");
    bytes32 public constant DOMAIN_VERSION = keccak256("1");
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "EIP712Domain(",
                "string name,",
                "string version,",
                "uint256 chainId,",
                "address verifyingContract",
                ")"
            )
        );
    bytes32 private constant _OPYN_RFQ_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "RFQ(uint256 offerId, uint256 bidId, address signerAddress, address bidderAddress, address bidToken, address offerToken, uint256 bidAmount, uint256 sellAmount,uint256 nonce)"
            )
        );
    bytes32 private constant _TEST_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "TEST(uint256 offerId, uint256 bidId)"
            )
        );
    bytes32 public immutable DOMAIN_SEPARATOR;

    uint256 public offersCounter;

    mapping(address => address) public bidderDelegator; // mapping between bidder address and delegator that can sign bid in place of bidder
    mapping(uint256 => OfferData) public _offers;
    mapping(address => Counters.Counter) private _nonces;

    struct BidData {
        uint256 offerId; // the ID of offer this bid relate to
        uint256 bidId; // bidId generated by paradigmco
        address signerAddress; // bid signer address (can be different than bidder address if this address is a bidder delegator)
        address bidderAddress; // bidder address (can be different than signer address if bidder authorize signer address is it is delegator)
        address bidToken; // bid token address
        address offerToken; // offer token address
        uint256 bidAmount; // bid amount to buy from offer
        uint256 sellAmount; // amount to sell of bidToken
        uint8 v; // v
        bytes32 r; // r
        bytes32 s; // s
    }

    struct TestData {
        uint256 offerId;
        uint256 bidId;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct OfferData {
        address seller; // seller address
        address offerToken; // offer token to sell
        address bidToken; // accepted token to bid with
        uint128 minPrice; // price of 1 offerToken demnominated in bidToken
        uint128 minBidSize; // min bid size
        uint256 totalSize; // offer total size
        uint256 offerTokenDecimals; // decimals of offer token
    }

    event CreateOffer(
        uint256 indexed offerId,
        address indexed seller,
        address indexed offerToken,
        address bidToken,
        uint128 minPrice,
        uint128 minBidSize,
        uint256 totalSize
    );
    event DelegateToSigner(address indexed bidder, address indexed newSigner);
    event SettleOffer(uint256 indexed offerId, uint256 bidId, address offerToken, address bidToken, address indexed seller, address indexed bidder, uint256 bidAmount, uint256 sellAmount);

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                DOMAIN_NAME,
                DOMAIN_VERSION,
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice create new onchain offer
     * @param _offerToken token address to sell
     * @param _bidToken token address to bid with
     * @param _minPrice min price of token to sell denominated in token to buy unit
     * @param _minBidSize min bid size
     * @param _totalSize total offer size
     */
    function createOffer(
        address _offerToken,
        address _bidToken,
        uint128 _minPrice,
        uint128 _minBidSize,
        uint256 _totalSize
    ) external returns (uint256) {
        require(_minPrice > 0, "Invalid minPrice");
        require(_minBidSize > 0, "Invalid minBidSize");

        uint256 offerId = offersCounter += 1;

        _offers[offerId].seller = msg.sender;
        _offers[offerId].offerToken = _offerToken;
        _offers[offerId].bidToken = _bidToken;
        _offers[offerId].minPrice = _minPrice;
        _offers[offerId].minBidSize = _minBidSize;
        _offers[offerId].totalSize = _totalSize;
        _offers[offerId].offerTokenDecimals = IERC20(_offerToken).decimals();

        emit CreateOffer(
            offerId,
            msg.sender,
            _offerToken,
            _bidToken,
            _minPrice,
            _minBidSize,
            _totalSize
        );

        return offerId;
    }

    /**
     * @notice delegate signing bid to another address
     * @param _signer new signer address
     */
    function delegateToSigner(address _signer) external {
        require(_signer != address(0), "Invalid signer address");

        bidderDelegator[msg.sender] = _signer;

        emit DelegateToSigner(msg.sender, _signer);
    }

    /**
     * @notice settlet offer
     * @param _offerId offer ID
     * @param _bidData BidData struct
     */
    function settleOffer(uint256 _offerId, BidData calldata _bidData) external {
        require(
            _offers[_offerId].seller == msg.sender,
            "Not authorized to settle"
        );
        require(
            (_offerId == _bidData.offerId) &&
                (_bidData.bidToken == _offers[_offerId].bidToken) &&
                (_bidData.offerToken == _offers[_offerId].offerToken) &&
                (_bidData.bidAmount >= _offers[_offerId].minBidSize),
            "Offer details do not match"
        );

        if (_bidData.bidderAddress != _bidData.signerAddress) {
            // check that signer was delegated by bidder to sign
            require(
                bidderDelegator[_bidData.bidderAddress] ==
                    _bidData.signerAddress,
                "Invalid signer for bidder address"
            );
        }

        address bidSigner = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    keccak256(
                        abi.encode(
                            _OPYN_RFQ_TYPEHASH,
                            _bidData.offerId,
                            _bidData.bidId,
                            _bidData.signerAddress,
                            _bidData.bidderAddress,
                            _bidData.bidToken,
                            _bidData.offerToken,
                            _bidData.bidAmount,
                            _bidData.sellAmount,
                            _useNonce(_bidData.signerAddress)
                        )
                    )
                )
            ),
            _bidData.v,
            _bidData.r,
            _bidData.s
        );

        require(bidSigner == _bidData.signerAddress, "Invalid bid signature");

        IERC20(_bidData.offerToken).transferFrom(
            msg.sender,
            _bidData.bidderAddress,
            _bidData.bidAmount
        );
        IERC20(_bidData.bidToken).transferFrom(
            _bidData.bidderAddress,
            msg.sender,
            _bidData.sellAmount
        );

        emit SettleOffer(_offerId, _bidData.bidId, _bidData.offerToken, _bidData.bidToken, msg.sender, _bidData.bidderAddress, _bidData.bidAmount, _bidData.sellAmount);
    }

    /**
     * @notice check bid errors
     * @param _bidData BidData struct
     * @return Number of errors found and array of error messages
     */
    function checkBid(BidData calldata _bidData) external view returns (uint256, bytes32[] memory) {
        OfferData memory offer = _offers[_bidData.offerId];

        require(offer.seller != address(0), "Offer does not exist");

        uint256 errCount;
        bytes32[] memory errors = new bytes32[](MAX_ERROR_COUNT);

        // Check signature
        address signerAddress = _getSigner(_bidData);

        if (signerAddress != _bidData.signerAddress) {
            errors[errCount] = "SIGNATURE_MISMATCHED";
            errCount++;
        }
        // Check signer is either bidder or bidder's delegator
        if (_bidData.bidderAddress != _bidData.signerAddress) {
            // check that signer was delegated by bidder to sign
            if (bidderDelegator[_bidData.bidderAddress] != _bidData.signerAddress) {
                errors[errCount] = "INVALID_SIGNER_FOR_BIDDER";
                errCount++;
            }
        }
        // Check bid size
        if (_bidData.bidAmount < offer.minBidSize) {
            errors[errCount] = "BID_TOO_SMALL";
            errCount++;
        }
        if (_bidData.bidAmount > offer.totalSize) {
            errors[errCount] = "BID_EXCEED_TOTAL_SIZE";
            errCount++;
        }
        // Check bid price
        uint256 bidPrice = (_bidData.sellAmount * 10**offer.offerTokenDecimals) / _bidData.bidAmount;
        if (bidPrice < offer.minPrice) {
            errors[errCount] = "PRICE_TOO_LOW";
            errCount++;
        }
        // Check signer allowance
        uint256 signerAllowance =
            IERC20(offer.bidToken).allowance(
                _bidData.bidderAddress,
                address(this)
            );
        if (signerAllowance < _bidData.sellAmount) {
            errors[errCount] = "BIDDER_ALLOWANCE_LOW";
            errCount++;
        }
        // Check seller allowance
        uint256 sellerAllowance =
            IERC20(offer.offerToken).allowance(offer.seller, address(this));
        if (sellerAllowance < _bidData.bidAmount) {
            errors[errCount] = "SELLER_ALLOWANCE_LOW";
            errCount++;
        }

        return (errCount, errors);
    }

    /**
     * @notice return signer address of a BidData struct
     * @param _bidData BidData struct
     * @return bid signer address
     */
    function getBidSigner(BidData calldata _bidData) external view returns (address) {
        return _getSigner(_bidData);
    }

    /**
     * @notice get nonce for specific address
     * @param _owner address
     * @return nonce 
     */
    function nonces(address _owner) external view returns (uint256) {
        return _nonces[_owner].current();
    }

    /**
     * @notice get offer details
     * @param _offerId offer ID
     * @return offer seller, token to sell, token to bid with, min price and min bid size
     */
    function getOfferDetails(uint256 _offerId)
        external
        view
        returns (
            address,
            address,
            address,
            uint128,
            uint128
        )
    {
        OfferData memory offer = _offers[_offerId];

        return (
            offer.seller,
            offer.offerToken,
            offer.bidToken,
            offer.minPrice,
            offer.minBidSize
        );
    }

    function _useNonce(address _owner) internal returns (uint256 current) {
        Counters.Counter storage nonce = _nonces[_owner];
        current = nonce.current();
        nonce.increment();
    }

    /**
     * @notice view function to get big signer address
     * @param _bidData BidData struct
     * @return signer address
     */
    function _getSigner(BidData calldata _bidData) internal view returns (address) {
        return ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    keccak256(
                        abi.encode(
                            _OPYN_RFQ_TYPEHASH,
                            _bidData.offerId,
                            _bidData.bidId,
                            _bidData.signerAddress,
                            _bidData.bidderAddress,
                            _bidData.bidToken,
                            _bidData.offerToken,
                            _bidData.bidAmount,
                            _bidData.sellAmount,
                            _nonces[_bidData.signerAddress].current()
                        )
                    )
                )
            ),
            _bidData.v,
            _bidData.r,
            _bidData.s
        );
    }

    function getTestSigner(TestData calldata _test) external view returns (address) {
        return ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    keccak256(
                        abi.encode(
                            _TEST_TYPEHASH,
                            _test.offerId,
                            _test.bidId
                        )
                    )
                )
            ),
            _test.v,
            _test.r,
            _test.s
        );
    }

    function getHashedMessage(TestData calldata _test) external view returns (bytes32) {
        return keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    keccak256(
                        abi.encode(
                            _TEST_TYPEHASH,
                            _test.offerId,
                            _test.bidId
                        )
                    )
                )
            );
    }

    function getEncode(TestData calldata _test) external view returns (bytes memory) {
        return abi.encode(
            _TEST_TYPEHASH,
            _test.offerId,
            _test.bidId
        );
    }
}
