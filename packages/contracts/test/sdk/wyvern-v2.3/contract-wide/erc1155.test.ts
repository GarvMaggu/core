import { Contract } from "@ethersproject/contracts";
import { parseEther } from "@ethersproject/units";
import * as Common from "@reservoir0x/sdk/src/common";
import * as WyvernV23 from "@reservoir0x/sdk/src/wyvern-v2.3";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { expect } from "chai";
import { ethers } from "hardhat";

import {
  getChainId,
  getCurrentTimestamp,
  reset,
  setupNFTs,
} from "../../../utils";

describe("WyvernV2.3 - ContractWideErc1155", () => {
  const chainId = getChainId();

  let deployer: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let carol: SignerWithAddress;

  let erc1155: Contract;

  beforeEach(async () => {
    [deployer, alice, bob, carol] = await ethers.getSigners();

    ({ erc1155 } = await setupNFTs(deployer));
  });

  afterEach(reset);

  it("Build and fill buy order", async () => {
    const buyer = alice;
    const seller = bob;
    const feeRecipient = carol;

    const price = parseEther("1");
    const fee = 250;
    const soldTokenId = 1;

    const weth = new Common.Helpers.Weth(ethers.provider, chainId);

    // Mint weth to buyer
    await weth.deposit(buyer, price);

    // Approve the token transfer proxy for the buyer
    await weth.approve(buyer, WyvernV23.Addresses.TokenTransferProxy[chainId]);

    // Approve the token transfer proxy for the seller
    await weth.approve(seller, WyvernV23.Addresses.TokenTransferProxy[chainId]);

    // Mint erc1155 to seller
    await erc1155.connect(seller).mint(soldTokenId);

    // Register user proxy for the seller
    const proxyRegistry = new WyvernV23.Helpers.ProxyRegistry(
      ethers.provider,
      chainId
    );
    await proxyRegistry.registerProxy(seller);
    const proxy = await proxyRegistry.getProxy(seller.address);

    const nft = new Common.Helpers.Erc1155(ethers.provider, erc1155.address);

    // Approve the user proxy
    await nft.approve(seller, proxy);

    const exchange = new WyvernV23.Exchange(chainId);

    const builder = new WyvernV23.Builders.Erc1155.ContractWide(chainId);

    // Build buy order
    let buyOrder = builder.build({
      maker: buyer.address,
      contract: erc1155.address,
      side: "buy",
      price,
      paymentToken: Common.Addresses.Weth[chainId],
      fee,
      feeRecipient: feeRecipient.address,
      listingTime: await getCurrentTimestamp(ethers.provider),
      nonce: await exchange.getNonce(ethers.provider, buyer.address),
    });

    // Sign the order
    await buyOrder.sign(buyer);

    // Create matching sell order
    const sellOrder = buyOrder.buildMatching(seller.address, {
      tokenId: soldTokenId,
      nonce: await exchange.getNonce(ethers.provider, seller.address),
    });
    sellOrder.params.listingTime = await getCurrentTimestamp(ethers.provider);

    await buyOrder.checkFillability(ethers.provider);

    const buyerWethBalanceBefore = await weth.getBalance(buyer.address);
    const sellerWethBalanceBefore = await weth.getBalance(seller.address);
    const feeRecipientWethBalanceBefore = await weth.getBalance(
      feeRecipient.address
    );
    const buyerErc1155BalanceBefore = await nft.getBalance(
      buyer.address,
      soldTokenId
    );
    const sellerErc1155BalanceBefore = await nft.getBalance(
      seller.address,
      soldTokenId
    );

    expect(buyerWethBalanceBefore).to.eq(price);
    expect(sellerWethBalanceBefore).to.eq(0);
    expect(feeRecipientWethBalanceBefore).to.eq(0);
    expect(buyerErc1155BalanceBefore).to.eq(0);
    expect(sellerErc1155BalanceBefore).to.eq(1);

    // Match orders
    await exchange.fillOrder(seller, buyOrder, sellOrder);

    const buyerWethBalanceAfter = await weth.getBalance(buyer.address);
    const sellerWethBalanceAfter = await weth.getBalance(seller.address);
    const feeRecipientWethBalanceAfter = await weth.getBalance(
      feeRecipient.address
    );
    const buyerErc1155BalanceAfter = await nft.getBalance(
      buyer.address,
      soldTokenId
    );
    const sellerErc1155BalanceAfter = await nft.getBalance(
      seller.address,
      soldTokenId
    );

    expect(buyerWethBalanceAfter).to.eq(0);
    expect(sellerWethBalanceAfter).to.eq(price.sub(price.mul(fee).div(10000)));
    expect(feeRecipientWethBalanceAfter).to.eq(price.mul(fee).div(10000));
    expect(buyerErc1155BalanceAfter).to.eq(1);
    expect(sellerErc1155BalanceAfter).to.eq(0);
  });
});
