// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IWETH} from "./interfaces/IWETH.sol";
import {ILooksRare, ILooksRareTransferSelectorNFT} from "./interfaces/ILooksRare.sol";
import {IWyvernV23, IWyvernV23ProxyRegistry} from "./interfaces/IWyvernV23.sol";

contract RouterV1 is Initializable, OwnableUpgradeable {
    enum ExchangeKind {
        WYVERN_V23,
        LOOKS_RARE,
        ZEROEX_V4
    }

    address public weth;

    address public looksRare;
    address public looksRareTransferManagerERC721;
    address public looksRareTransferManagerERC1155;

    address public wyvernV23;
    address public wyvernV23Proxy;

    address public zeroExV4;

    function initialize(
        address wethAddress,
        address looksRareAddress,
        address wyvernV23Address,
        address zeroExV4Address
    ) public initializer {
        OwnableUpgradeable.__Ownable_init();

        weth = wethAddress;

        // --- LooksRare setup ---

        looksRare = looksRareAddress;

        // Cache the transfer manager contracts
        address transferSelectorNFT = ILooksRare(looksRare)
            .transferSelectorNFT();
        looksRareTransferManagerERC721 = ILooksRareTransferSelectorNFT(
            transferSelectorNFT
        ).TRANSFER_MANAGER_ERC721();
        looksRareTransferManagerERC1155 = ILooksRareTransferSelectorNFT(
            transferSelectorNFT
        ).TRANSFER_MANAGER_ERC1155();

        // --- WyvernV23 setup ---

        wyvernV23 = wyvernV23Address;

        // Create a user proxy
        address proxyRegistry = IWyvernV23(wyvernV23).registry();
        IWyvernV23ProxyRegistry(proxyRegistry).registerProxy();
        wyvernV23Proxy = IWyvernV23ProxyRegistry(proxyRegistry).proxies(
            address(this)
        );

        // Approve the token transfer proxy
        IERC20(weth).approve(
            IWyvernV23(wyvernV23).tokenTransferProxy(),
            type(uint256).max
        );

        // --- ZeroExV4 setup ---

        zeroExV4 = zeroExV4Address;
    }

    receive() external payable {
        // For unwrapping WETH
    }

    function makeCalls(
        address[] calldata targets,
        bytes[] calldata data,
        uint256[] calldata values
    ) external payable onlyOwner {
        bool success;
        for (uint256 i = 0; i < targets.length; i++) {
            (success, ) = payable(targets[i]).call{value: values[i]}(data[i]);
            require(success, "Unsuccessfull call");
        }
    }

    // Terminology:
    // - "single" -> buy single token
    // - "batch" -> buy multiple tokens (natively, only 0xv4 supports this)
    // - "multi" -> buy multiple tokens (via the router)

    function singleERC721ListingFill(
        address referrer,
        bytes memory data,
        ExchangeKind exchangeKind,
        address collection,
        uint256 tokenId,
        address receiver,
        uint16 feeBps
    ) external payable {
        address target;
        if (exchangeKind == ExchangeKind.WYVERN_V23) {
            target = wyvernV23;
        } else if (exchangeKind == ExchangeKind.LOOKS_RARE) {
            target = looksRare;
        } else if (exchangeKind == ExchangeKind.ZEROEX_V4) {
            target = zeroExV4;
        } else {
            revert("Unsupported exchange");
        }

        uint256 payment = (10000 * msg.value) / (10000 + feeBps);

        (bool success, ) = target.call{value: payment}(data);
        require(success, "Unsuccessfull fill");

        if (exchangeKind != ExchangeKind.WYVERN_V23) {
            // When filling LooksRare or ZeroExV4 listings we need to send
            // the NFT to the taker's wallet after the fill (since they do
            // not allow specifying a different recipient than the taker).
            IERC721(collection).transferFrom(address(this), receiver, tokenId);
        }

        uint256 fee = msg.value - payment;
        if (fee > 0) {
            (success, ) = payable(referrer).call{value: fee}("");
            require(success, "Could not send payment");
        }
    }

    function singleERC721BidFill(
        address, // referrer
        bytes calldata data,
        ExchangeKind exchangeKind,
        address collection,
        address receiver,
        bool unwrapWeth
    ) external payable {
        address target;
        address operator;
        if (exchangeKind == ExchangeKind.WYVERN_V23) {
            target = wyvernV23;
            operator = wyvernV23Proxy;
        } else if (exchangeKind == ExchangeKind.LOOKS_RARE) {
            target = looksRare;
            operator = looksRareTransferManagerERC721;
        } else if (exchangeKind == ExchangeKind.ZEROEX_V4) {
            target = zeroExV4;
            operator = zeroExV4;
        } else {
            revert("Unsupported exchange");
        }

        // Approve the exchange to transfer the NFT out of the router.
        bool isApproved = IERC721(collection).isApprovedForAll(
            address(this),
            operator
        );
        if (!isApproved) {
            IERC721(collection).setApprovalForAll(operator, true);
        }

        (bool success, ) = target.call{value: msg.value}(data);
        require(success, "Unsuccessfull fill");

        // Send the payment to the actual taker.
        uint256 balance = IERC20(weth).balanceOf(address(this));
        if (unwrapWeth) {
            IWETH(weth).withdraw(balance);
            (success, ) = payable(receiver).call{value: balance}("");
            require(success, "Could not send payment");
        } else {
            IERC20(weth).transfer(receiver, balance);
        }
    }

    function singleERC1155ListingFill(
        address referrer,
        bytes memory data,
        ExchangeKind exchangeKind,
        address collection,
        uint256 tokenId,
        uint256 amount,
        address receiver,
        uint256 feeBps
    ) external payable {
        address target;
        if (exchangeKind == ExchangeKind.WYVERN_V23) {
            target = wyvernV23;
        } else if (exchangeKind == ExchangeKind.LOOKS_RARE) {
            target = looksRare;
        } else if (exchangeKind == ExchangeKind.ZEROEX_V4) {
            target = zeroExV4;
        } else {
            revert("Unsupported exchange");
        }

        uint256 payment = (10000 * msg.value) / (10000 + feeBps);

        (bool success, ) = target.call{value: payment}(data);
        require(success, "Unsuccessfull fill");

        if (exchangeKind != ExchangeKind.WYVERN_V23) {
            // When filling LooksRare or ZeroExV4 listings we need to send
            // the NFT to the taker's wallet after the fill (since they do
            // not allow specifying a different recipient than the taker).
            IERC1155(collection).safeTransferFrom(
                address(this),
                receiver,
                tokenId,
                amount,
                ""
            );
        }

        uint256 fee = msg.value - payment;
        if (fee > 0) {
            (success, ) = payable(referrer).call{value: fee}("");
            require(success, "Could not send payment");
        }
    }

    function batchERC1155ListingFill(
        address referrer,
        bytes memory data,
        ExchangeKind exchangeKind,
        address[] memory collections,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        address receiver,
        uint256 feeBps
    ) external payable {
        address target;
        if (exchangeKind == ExchangeKind.ZEROEX_V4) {
            target = zeroExV4;
        } else {
            revert("Unsupported exchange");
        }

        uint256 payment = (10000 * msg.value) / (10000 + feeBps);

        (bool success, ) = target.call{value: payment}(data);
        require(success, "Unsuccessfull fill");

        for (uint256 i = 0; i < collections.length; i++) {
            // When filling LooksRare or ZeroExV4 listings we need to send
            // the NFT to the taker's wallet after the fill (since they do
            // not allow specifying a different recipient than the taker).
            IERC1155(collections[i]).safeTransferFrom(
                address(this),
                receiver,
                tokenIds[i],
                amounts[i],
                ""
            );
        }

        uint256 fee = msg.value - payment;
        if (fee > 0) {
            (success, ) = payable(referrer).call{value: fee}("");
            require(success, "Could not send payment");
        }
    }

    function singleERC1155BidFill(
        address, // referrer
        bytes memory data,
        ExchangeKind exchangeKind,
        address collection,
        address receiver,
        bool unwrapWeth
    ) external payable {
        address target;
        address operator;
        if (exchangeKind == ExchangeKind.WYVERN_V23) {
            target = wyvernV23;
            operator = wyvernV23Proxy;
        } else if (exchangeKind == ExchangeKind.LOOKS_RARE) {
            target = looksRare;
            operator = looksRareTransferManagerERC1155;
        } else if (exchangeKind == ExchangeKind.ZEROEX_V4) {
            target = zeroExV4;
            operator = zeroExV4;
        } else {
            revert("Unsupported exchange");
        }

        // Approve the exchange to transfer the NFT out of the router.
        bool isApproved = IERC1155(collection).isApprovedForAll(
            address(this),
            operator
        );
        if (!isApproved) {
            IERC1155(collection).setApprovalForAll(operator, true);
        }

        (bool success, ) = target.call{value: msg.value}(data);
        require(success, "Unsuccessfull fill");

        // Send the payment to the actual taker.
        uint256 balance = IERC20(weth).balanceOf(address(this));
        if (unwrapWeth) {
            IWETH(weth).withdraw(balance);
            (success, ) = payable(receiver).call{value: balance}("");
            require(success, "Could not send payment");
        } else {
            IERC20(weth).transfer(receiver, balance);
        }
    }

    function multiListingFill(
        bytes[] calldata data,
        uint256[] calldata values,
        bool revertIfIncomplete
    ) external payable {
        bool success;
        for (uint256 i = 0; i < data.length; i++) {
            (success, ) = address(this).call{value: values[i]}(data[i]);
            if (revertIfIncomplete) {
                require(success, "Atomic fill failed");
            }
        }

        (success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "Could not send payment");
    }

    // ERC721 / ERC1155 overrides

    function onERC721Received(
        address, // operator,
        address, // from
        uint256, // tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        if (data.length == 0) {
            return this.onERC721Received.selector;
        }

        bytes4 selector = bytes4(data[:4]);
        require(
            selector == this.singleERC721BidFill.selector,
            "Wrong selector"
        );

        (bool success, ) = address(this).call(data);
        require(success, "Unsuccessfull fill");

        return this.onERC721Received.selector;
    }

    function onERC1155Received(
        address, // operator
        address, // from
        uint256, // tokenId
        uint256, // amount
        bytes calldata data
    ) external returns (bytes4) {
        if (data.length == 0) {
            return this.onERC1155Received.selector;
        }

        bytes4 selector = bytes4(data[:4]);
        require(
            selector == this.singleERC1155BidFill.selector,
            "Wrong selector"
        );

        (bool success, ) = address(this).call(data);
        require(success, "Unsuccessfull fill");

        return this.onERC1155Received.selector;
    }
}
