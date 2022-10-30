import { Contract } from "@ethersproject/contracts";

import * as Addresses from "./addresses";
import { TxData, bn, generateReferrerBytes } from "../utils";

import ExchangeAbi from "./abis/Router.json";

export class Exchange {
  public chainId: number;
  public contract: Contract;

  constructor(chainId: number) {
    this.chainId = chainId;
    this.contract = new Contract(
      Addresses.BlurMarketplace2[this.chainId],
      ExchangeAbi as any
    );
  }

  // --- Fill order ---
  public fillOrderTx(
    taker: string,
    sellData: [],
    buyData: [],
    price: string,
    options?: {
      referrer?: string;
    }
  ): TxData {
    let data: string;
    let value: string | undefined;
    data = this.contract.interface.encodeFunctionData("execute", [
      sellData,
      buyData,
    ]);
    value = price;

    return {
      from: taker,
      to: this.contract.address,
      data: data + generateReferrerBytes(options?.referrer),
      value: value && bn(value).toHexString(),
    };
  }
}
