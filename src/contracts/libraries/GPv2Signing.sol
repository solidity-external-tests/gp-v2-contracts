// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;

/// @title Gnosis Protocol v2 Signing Library.
/// @author Gnosis Developers
library GPv2Signing {
    /// @dev The length of any signature from an externally owned account.
    uint256 private constant ECDSA_SIGNATURE_LENGTH = 65;

    /// @dev Decodes ECDSA signatures from calldata.
    ///
    /// The first bytes of the input tightly pack the signature parameters
    /// specified in the following struct:
    ///
    /// ```
    /// struct EncodedSignature {
    ///     bytes32 r;
    ///     bytes32 s;
    ///     uint8 v;
    /// }
    /// ```
    ///
    /// Unused signature data is returned along with the address of the signer.
    /// If the encoding is not valid, for example because the calldata does not
    /// suffice, the function reverts.
    ///
    /// @param encodedSignature Calldata pointing to tightly packed signature
    /// bytes.
    /// @return r r parameter of the ECDSA signature.
    /// @return s s parameter of the ECDSA signature.
    /// @return v v parameter of the ECDSA signature.
    /// @return remainingCalldata Input calldata that has not been used to
    /// decode the signature.
    function decodeEcdsaSignature(bytes calldata encodedSignature)
        internal
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v,
            bytes calldata remainingCalldata
        )
    {
        require(
            encodedSignature.length >= ECDSA_SIGNATURE_LENGTH,
            "GPv2: invalid encoding"
        );

        // NOTE: Use assembly to efficiently decode signature data.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // r = uint256(encodedSignature[0:32])
            r := calldataload(encodedSignature.offset)
            // s = uint256(encodedSignature[32:64])
            s := calldataload(add(encodedSignature.offset, 32))
            // v = uint8(encodedSignature[64])
            v := shr(248, calldataload(add(encodedSignature.offset, 64)))
        }

        // NOTE: Use assembly to slice the calldata bytes without generating
        // code for bounds checking.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            remainingCalldata.offset := add(
                encodedSignature.offset,
                ECDSA_SIGNATURE_LENGTH
            )
            remainingCalldata.length := sub(
                encodedSignature.length,
                ECDSA_SIGNATURE_LENGTH
            )
        }
    }

    /// @dev Decodes signature bytes originating from an EIP-712-encoded
    /// signature.
    ///
    /// EIP-712 signs typed data. The specifications are described in the
    /// related EIP (<https://eips.ethereum.org/EIPS/eip-712>).
    ///
    /// EIP-712 signatures are encoded as standard ECDSA signatures as described
    /// in the corresponding decoding function [`decodeEcdsaSignature`].
    ///
    /// Unused signature data is returned along with the address of the signer.
    /// If the signature is not valid, the function reverts.
    ///
    /// @param encodedSignature Calldata pointing to tightly packed signature
    /// bytes.
    /// @param domainSeparator The domain separator used for signing the order.
    /// @param orderDigest The EIP-712 signing digest derived from the order
    /// parameters.
    /// @return owner The address of the signer.
    /// @return remainingCalldata Input calldata that has not been used to
    /// decode the current order.
    function recoverEip712Signer(
        bytes calldata encodedSignature,
        bytes32 domainSeparator,
        bytes32 orderDigest
    ) internal pure returns (address owner, bytes calldata remainingCalldata) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        (r, s, v, remainingCalldata) = decodeEcdsaSignature(encodedSignature);

        uint256 freeMemoryPointer = getFreeMemoryPointer();

        bytes32 signingDigest =
            keccak256(
                abi.encodePacked("\x19\x01", domainSeparator, orderDigest)
            );

        owner = ecrecover(signingDigest, v, r, s);
        require(owner != address(0), "GPv2: invalid eip712 signature");

        setFreeMemoryPointer(freeMemoryPointer);
    }

    /// @dev Decodes signature bytes originating from the output of the eth_sign
    /// RPC call.
    ///
    /// The specifications are described in the Ethereum documentation
    /// (<https://eth.wiki/json-rpc/API#eth_sign>).
    ///
    /// eth_sign signatures are encoded as standard ECDSA signatures as
    /// described in the corresponding decoding function
    /// [`decodeEcdsaSignature`].
    ///
    /// Unused signature data is returned along with the address of the signer.
    /// If the signature is not valid, the function reverts.
    ///
    /// @param encodedSignature Calldata pointing to tightly packed signature
    /// bytes.
    /// @param domainSeparator The domain separator used for signing the order.
    /// @param orderDigest The EIP-712 signing digest derived from the order
    /// parameters.
    /// @return owner The address of the signer.
    /// @return remainingCalldata Input calldata that has not been used to
    /// decode the current order.
    function recoverEthsignSigner(
        bytes calldata encodedSignature,
        bytes32 domainSeparator,
        bytes32 orderDigest
    ) internal pure returns (address owner, bytes calldata remainingCalldata) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        (r, s, v, remainingCalldata) = decodeEcdsaSignature(encodedSignature);

        uint256 freeMemoryPointer = getFreeMemoryPointer();

        // The signed message is encoded as:
        // `"\x19Ethereum Signed Message:\n" || length || data`, where
        // the length is a constant (64 bytes) and the data is defined as:
        // `domainSeparator || orderDigest`.
        bytes32 signingDigest =
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n64",
                    domainSeparator,
                    orderDigest
                )
            );

        owner = ecrecover(signingDigest, v, r, s);
        require(owner != address(0), "GPv2: invalid ethsign signature");

        setFreeMemoryPointer(freeMemoryPointer);
    }

    /// @dev Returns a pointer to the first location in memory that has not
    /// been allocated by the code at this point in the code.
    ///
    /// @return pointer A pointer to the first unallocated location in memory.
    function getFreeMemoryPointer() private pure returns (uint256 pointer) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            pointer := mload(0x40)
        }
    }

    /// @dev Manually sets the pointer that specifies the first location in
    /// memory that is available to be allocated. It allows to free unused
    /// allocated memory, but if used incorrectly it could lead to the same
    /// address in memory being used twice.
    ///
    /// This function exists to deallocate memory for operations that allocate
    /// memory during their execution but do not free it after use.
    /// Examples are:
    /// - calling the ABI encoding methods
    /// - calling the `ecrecover` precompile.
    /// If we reset the free memory pointer to what it was before the execution
    /// of these operations, we effectively deallocated the memory used by them.
    /// This is safe as the memory used can be discarded, and the memory pointed
    /// to by the free memory pointer **does not have to point to zero-ed out
    /// memory**.
    /// <https://docs.soliditylang.org/en/v0.7.6/internals/layout_in_memory.html>
    ///
    /// @param pointer A pointer to a location in memory.
    function setFreeMemoryPointer(uint256 pointer) private pure {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(0x40, pointer)
        }
    }
}
