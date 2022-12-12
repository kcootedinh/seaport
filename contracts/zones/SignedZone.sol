// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ZoneInterface } from "../interfaces/ZoneInterface.sol";

import {
    SignedZoneEventsAndErrors
} from "./interfaces/SignedZoneEventsAndErrors.sol";

import { ZoneParameters } from "../lib/ConsiderationStructs.sol";

import { SignedZoneInterface } from "./interfaces/SignedZoneInterface.sol";

import {
    Ownable2Step
} from "../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/**
 * @title  SignedZone
 * @author ryanio
 * @notice SignedZone is a zone implementation that requires orders
 *         to be signed by an approved signer.
 */
contract SignedZone is
    SignedZoneEventsAndErrors,
    ZoneInterface,
    SignedZoneInterface,
    Ownable2Step
{
    /// @dev The allowed signers.
    mapping(address => bool) private _signers;

    /// @dev The EIP-712 digest parameters.
    bytes32 internal immutable _NAME_HASH = keccak256(bytes("SignedZone"));
    bytes32 internal immutable _VERSION_HASH = keccak256(bytes("1.0"));
    // prettier-ignore
    bytes32 internal immutable _EIP_712_DOMAIN_TYPEHASH = keccak256(
          abi.encodePacked(
            "EIP712Domain(",
                "string name,",
                "string version,",
                "uint256 chainId,",
                "address verifyingContract",
            ")"
          )
        );
    // prettier-ignore
    bytes32 internal immutable _SIGNED_ORDER_TYPEHASH = keccak256(
          abi.encodePacked(
            "SignedOrder(",
                "address fulfiller,",
                "uint256 expiration,",
                "bytes32 orderHash",
            ")"
          )
        );
    uint256 internal immutable _CHAIN_ID = block.chainid;
    bytes32 internal immutable _DOMAIN_SEPARATOR;

    /// @dev ECDSA signature offsets.
    uint256 constant ECDSA_MaxLength = 65;
    uint256 constant ECDSA_signature_s_offset = 0x40;
    uint256 constant ECDSA_signature_v_offset = 0x60;

    /// @dev Helpers for memory offsets.
    uint256 constant OneWord = 0x20;
    uint256 constant TwoWords = 0x40;
    uint256 constant ThreeWords = 0x60;
    uint256 constant FourWords = 0x80;
    uint256 constant FiveWords = 0xa0;
    uint256 constant Signature_lower_v = 27;
    uint256 constant MaxUint8 = 0xff;
    bytes32 constant EIP2098_allButHighestBitMask = (
        0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    );
    uint256 constant Ecrecover_precompile = 1;
    uint256 constant Ecrecover_args_size = 0x80;
    uint256 constant FreeMemoryPointerSlot = 0x40;
    uint256 constant ZeroSlot = 0x60;
    uint256 constant Slot0x80 = 0x80;

    /// @dev The EIP-712 digest offsets.
    uint256 constant EIP712_DomainSeparator_offset = 0x02;
    uint256 constant EIP712_SignedOrderHash_offset = 0x22;
    uint256 constant EIP712_DigestPayload_size = 0x42;
    uint256 constant EIP_712_PREFIX = (
        0x1901000000000000000000000000000000000000000000000000000000000000
    );

    /**
     * @notice Constructor to deploy the contract.
     */
    constructor() {
        _DOMAIN_SEPARATOR = _deriveDomainSeparator();
    }

    /**
     * @notice Add a new signer.
     *
     * @param signer The new signer address to add.
     */
    function addSigner(address signer) external onlyOwner {
        if (signer == address(0)) {
            revert SignerCannotBeZeroAddress();
        }

        if (_signers[signer] == true) {
            revert SignerAlreadyAdded(signer);
        }

        // Add the signer in the mapping.
        _signers[signer] = true;

        // Emit an event that the signer was added.
        emit SignerAdded(signer);
    }

    /**
     * @notice Remove an active signer.
     *
     * @param signer The signer address to remove.
     */
    function removeSigner(address signer) external onlyOwner {
        if (_signers[signer] == false) {
            revert SignerNotPresent(signer);
        }

        // Remove the signer in the mapping.
        _signers[signer] = false;

        // Emit an event that the signer was removed.
        emit SignerRemoved(signer);
    }

    /**
     * @notice Check if a given order including extraData is currently valid.
     *
     * @dev This function is called by Seaport whenever any extraData is
     *      provided by the caller.
     *
     * @return validOrderMagicValue A magic value indicating if the order is
     *                              currently valid.
     */
    function validateOrder(
        ZoneParameters calldata zoneParameters
    ) external view override returns (bytes4 validOrderMagicValue) {
        // Set the fulfiller, expiration, and signature from the extraData.
        bytes calldata extraData = zoneParameters.extraData;
        // bytes 0-20: expected fulfiller (zero address means not restricted)
        address expectedFulfiller = address(bytes20(extraData[:20]));
        // bytes 20-52: expiration timestamp
        uint256 expiration = uint256(bytes32(extraData[20:52]));
        // bytes 52-117: signature (supports 64 byte compact sig, EIP-2098)
        bytes calldata signature = extraData[52:];

        // Put orderHash and fulfiller on the stack for more efficient access.
        bytes32 orderHash = zoneParameters.orderHash;
        address actualFulfiller = zoneParameters.fulfiller;

        // Revert if expired.
        if (block.timestamp > expiration) {
            revert SignatureExpired(expiration, orderHash);
        }

        // Revert if expected fulfiller is not the zero address and does
        // not match the actual fulfiller.
        bool validFulfiller;
        assembly {
            validFulfiller := or(
                iszero(expectedFulfiller),
                eq(expectedFulfiller, actualFulfiller)
            )
        }
        if (!validFulfiller) {
            revert InvalidFulfiller(
                expectedFulfiller,
                actualFulfiller,
                orderHash
            );
        }

        // Derive the signedOrder hash.
        bytes32 signedOrderHash = _deriveSignedOrderHash(
            expectedFulfiller,
            expiration,
            orderHash
        );

        // Derive the EIP-712 digest using the domain separator and signedOrder
        // hash.
        bytes32 digest = _deriveEIP712Digest(
            _domainSeparator(),
            signedOrderHash
        );

        // Recover the signer address from the digest and signature.
        address recoveredSigner = _recoverSigner(digest, signature);

        // Revert if the signer is not approved.
        if (_signers[recoveredSigner] != true) {
            revert SignerNotApproved(recoveredSigner, orderHash);
        }

        // Return the selector of validateOrder as the magic value.
        validOrderMagicValue = ZoneInterface.validateOrder.selector;
    }

    /**
     * @dev Derive the signedOrder hash from the orderHash and expiration.
     *
     * @param fulfiller        The expected fulfiller address.
     * @param expiration       The signature expiration timestamp.
     * @param orderHash        The order hash.
     *
     * @return signedOrderHash The signedOrder hash.
     *
     */
    function _deriveSignedOrderHash(
        address fulfiller,
        uint256 expiration,
        bytes32 orderHash
    ) internal view returns (bytes32 signedOrderHash) {
        // Derive the signed order hash.
        signedOrderHash = keccak256(
            abi.encode(_SIGNED_ORDER_TYPEHASH, fulfiller, expiration, orderHash)
        );
    }

    /**
     * @dev Internal view function to return the signer of a signature.
     *
     * @param digest           The digest to verify the signature against.
     * @param signature        A signature from the signer indicating that the
     *                         order has been approved.
     *
     * @return recoveredSigner The recovered signer.
     */
    function _recoverSigner(
        bytes32 digest,
        bytes memory signature
    ) internal view returns (address recoveredSigner) {
        // Utilize assembly to perform optimized signature verification check.
        assembly {
            // Ensure that first word of scratch space is empty.
            mstore(0, 0)

            // Declare value for v signature parameter.
            let v

            // Get the length of the signature.
            let signatureLength := mload(signature)

            // Get the pointer to the value preceding the signature length.
            // This will be used for temporary memory overrides - either the
            // signature head for isValidSignature or the digest for ecrecover.
            let wordBeforeSignaturePtr := sub(signature, OneWord)

            // Cache the current value behind the signature to restore it later.
            let cachedWordBeforeSignature := mload(wordBeforeSignaturePtr)

            // Declare lenDiff + recoveredSigner scope to manage stack pressure.
            {
                // Take the difference between the max ECDSA signature length
                // and the actual signature length. Overflow desired for any
                // values > 65. If the diff is not 0 or 1, it is not a valid
                // ECDSA signature - move on to EIP1271 check.
                let lenDiff := sub(ECDSA_MaxLength, signatureLength)

                // If diff is 0 or 1, it may be an ECDSA signature.
                // Try to recover signer.
                if iszero(gt(lenDiff, 1)) {
                    // Read the signature `s` value.
                    let originalSignatureS := mload(
                        add(signature, ECDSA_signature_s_offset)
                    )

                    // Read the first byte of the word after `s`. If the
                    // signature is 65 bytes, this will be the real `v` value.
                    // If not, it will need to be modified - doing it this way
                    // saves an extra condition.
                    v := byte(
                        0,
                        mload(add(signature, ECDSA_signature_v_offset))
                    )

                    // If lenDiff is 1, parse 64-byte signature as ECDSA.
                    if lenDiff {
                        // Extract yParity from highest bit of vs and add 27 to
                        // get v.
                        v := add(
                            shr(MaxUint8, originalSignatureS),
                            Signature_lower_v
                        )

                        // Extract canonical s from vs, all but the highest bit.
                        // Temporarily overwrite the original `s` value in the
                        // signature.
                        mstore(
                            add(signature, ECDSA_signature_s_offset),
                            and(
                                originalSignatureS,
                                EIP2098_allButHighestBitMask
                            )
                        )
                    }
                    // Temporarily overwrite the signature length with `v` to
                    // conform to the expected input for ecrecover.
                    mstore(signature, v)

                    // Temporarily overwrite the word before the length with
                    // `digest` to conform to the expected input for ecrecover.
                    mstore(wordBeforeSignaturePtr, digest)

                    // Attempt to recover the signer for the given signature. Do
                    // not check the call status as ecrecover will return a null
                    // address if the signature is invalid.
                    pop(
                        staticcall(
                            gas(),
                            Ecrecover_precompile, // Call ecrecover precompile.
                            wordBeforeSignaturePtr, // Use data memory location.
                            Ecrecover_args_size, // Size of digest, v, r, and s.
                            0, // Write result to scratch space.
                            OneWord // Provide size of returned result.
                        )
                    )

                    // Restore cached word before signature.
                    mstore(wordBeforeSignaturePtr, cachedWordBeforeSignature)

                    // Restore cached signature length.
                    mstore(signature, signatureLength)

                    // Restore cached signature `s` value.
                    mstore(
                        add(signature, ECDSA_signature_s_offset),
                        originalSignatureS
                    )

                    // Read the recovered signer from the buffer given as return
                    // space for ecrecover.
                    recoveredSigner := mload(0)
                }
            }

            // Restore the cached values overwritten by selector, digest and
            // signature head.
            mstore(wordBeforeSignaturePtr, cachedWordBeforeSignature)
        }
    }

    /**
     * @dev Internal pure function to efficiently derive an digest to sign for
     *      an order in accordance with EIP-712.
     *
     * @param domainSeparator The domain separator.
     * @param signedOrderHash The signedOrder hash.
     *
     * @return digest The digest hash.
     */
    function _deriveEIP712Digest(
        bytes32 domainSeparator,
        bytes32 signedOrderHash
    ) internal pure returns (bytes32 digest) {
        // Leverage scratch space to perform an efficient hash.
        assembly {
            // Place the EIP-712 prefix at the start of scratch space.
            mstore(0, EIP_712_PREFIX)

            // Place the domain separator in the next region of scratch space.
            mstore(EIP712_DomainSeparator_offset, domainSeparator)

            // Place the signed order hash in scratch space, spilling into the
            // first two bytes of the free memory pointer — this should never be
            // set as memory cannot be expanded to that size, and will be
            // zeroed out after the hash is performed.
            mstore(EIP712_SignedOrderHash_offset, signedOrderHash)

            // Hash the relevant region
            digest := keccak256(0, EIP712_DigestPayload_size)

            // Clear out the dirtied bits in the memory pointer.
            mstore(EIP712_SignedOrderHash_offset, 0)
        }
    }

    /**
     * @dev Internal view function to get the EIP-712 domain separator. If the
     *      chainId matches the chainId set on deployment, the cached domain
     *      separator will be returned; otherwise, it will be derived from
     *      scratch.
     *
     * @return The domain separator.
     */
    function _domainSeparator() internal view returns (bytes32) {
        // prettier-ignore
        return block.chainid == _CHAIN_ID
            ? _DOMAIN_SEPARATOR
            : _deriveDomainSeparator();
    }

    /**
     * @dev Internal view function to derive the EIP-712 domain separator.
     *
     * @return domainSeparator The derived domain separator.
     */
    function _deriveDomainSeparator()
        internal
        view
        returns (bytes32 domainSeparator)
    {
        bytes32 typehash = _EIP_712_DOMAIN_TYPEHASH;
        bytes32 nameHash = _NAME_HASH;
        bytes32 versionHash = _VERSION_HASH;

        // Leverage scratch space and other memory to perform an efficient hash.
        assembly {
            // Retrieve the free memory pointer; it will be replaced afterwards.
            let freeMemoryPointer := mload(FreeMemoryPointerSlot)

            // Retrieve value at 0x80; it will also be replaced afterwards.
            let slot0x80 := mload(Slot0x80)

            // Place typehash, name hash, and version hash at start of memory.
            mstore(0, typehash)
            mstore(OneWord, nameHash)
            mstore(TwoWords, versionHash)

            // Place chainId in the next memory location.
            mstore(ThreeWords, chainid())

            // Place the address of this contract in the next memory location.
            mstore(FourWords, address())

            // Hash relevant region of memory to derive the domain separator.
            domainSeparator := keccak256(0, FiveWords)

            // Restore the free memory pointer.
            mstore(FreeMemoryPointerSlot, freeMemoryPointer)

            // Restore the zero slot to zero.
            mstore(ZeroSlot, 0)

            // Restore the value at 0x80.
            mstore(Slot0x80, slot0x80)
        }
    }

    /**
     * @dev Public view function to retrieve configuration information for
     *      this contract.
     *
     * @return domainSeparator The domain separator for this contract.
     */
    function information() external view returns (bytes32 domainSeparator) {
        // Derive the domain separator.
        domainSeparator = _domainSeparator();
    }
}
