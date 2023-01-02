import { Contract } from "@ethersproject/contracts";

import * as Addresses from "./addresses";
import { TxData, bn } from "../utils";

import ExchangeAbi from "./abis/Router.json";

export class Exchange {
  public chainId: number;
  public contract: Contract;

  constructor(chainId: number) {
    this.chainId = chainId;
    this.contract = new Contract(
      Addresses.BlurSwap[this.chainId],
      ExchangeAbi as any
    );
  }

  // --- Fill order ---
  public fillOrderTx(
    taker: string,
    inputData: any,
    price: string,
    options?: {
      referrer?: string;
    }
  ): TxData {
    let data: string;
    let value: string | undefined;
    data = this.contract.interface.encodeFunctionData("batchBuyWithETH", [
      inputData,
    ]);
    value = price;

    return {
      from: taker,
      to: this.contract.address,
      data: data,
      value: value && bn(value).toHexString(),
    };
  }
}
